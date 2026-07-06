import threading
import time
import re
import cv2
import numpy as np

# ============================================================
# PID CONTROLLER
# ============================================================

class PIDController:
    """PID discreto. Equivalente al del proyecto de referencia."""
    def __init__(self, kp: float, ki: float, kd: float,
                 output_min: float = -100, output_max: float = 100):
        self.kp = kp
        self.ki = ki
        self.kd = kd
        self.output_min = output_min
        self.output_max = output_max
        self.error = 0.0
        self.error_last = 0.0
        self.integral_error = 0.0
        self.derivative_error = 0.0
        self.velocity_command = 0.0

    def compute(self, error: float, dt: float) -> float:
        if dt <= 0:
            return 0.0
        self.error = error
        self.integral_error += error * dt
        # Clamp ki*integral to output range (anti-windup on the I contribution, not the raw accumulator)
        if self.ki != 0:
            i_max = abs(self.output_max / self.ki)
            self.integral_error = max(-i_max, min(i_max, self.integral_error))
        self.derivative_error = (error - self.error_last) / dt
        self.error_last = error
        output = self.kp * self.error + self.ki * self.integral_error + self.kd * self.derivative_error
        output = max(self.output_min, min(self.output_max, output))
        self.velocity_command = output
        return output

    def reset_integral(self) -> None:
        self.integral_error = 0.0


# ============================================================
# FOLLOW CONTROLLER  
# ============================================================

# Ganancias PID
GAINS_YAW_PID         = (0.2,  0.002,  0.1)   # kp, ki, kd
# Altitud: error en píxeles → velocidad ud cm/s
GAINS_ALTITUDE_PID    = (-0.08,  -0.002,  -0.020)
# Forward/back ToF: error en cm → velocidad fb cm/s
# kd alto para anticipar la parada (frenar antes) y kp algo menor para no
# empujar agresivo lejos del setpoint: reduce el overshoot cuando el ToF/vídeo
# llega con retraso y el dron "se pasa de largo" al acercarse a la persona.
GAINS_FORWARD_BACK_TOF_PID  = (-0.45,  -0.03,  -0.85)
# Forward/back bbox: error en ratio → velocidad fb cm/s
GAINS_FORWARD_BACK_BBOX_PID = (-70.0, -8.0,  -150.0)
# Límites de velocidad. Subidos para que el Follow no vaya lento al seguir:
# yaw/altitud más ágiles para no quedarse atrás cuando la persona se mueve, y
# fb mayor para cerrar distancia antes. NOTA: lejos del setpoint el término P de
# pitch SATURA (P = kp*error >> límite), así que FB_MAX_VELOCITY es directamente la
# velocidad de aproximación cuando la persona está LEJOS. Subido 32→50 porque a 32
# cm/s el dron no alcanzaba a una persona andando (~140 cm/s) y "venía muy lento".
# Si aparece overshoot/oscilación al acercarse, bajar FB_MAX_VELOCITY o subir el kd
# de GAINS_FORWARD_BACK_TOF_PID (banco).
YAW_MAX_VELOCITY      = 55
UD_MAX_VELOCITY       = 35
FB_MAX_VELOCITY       = 50

# Banda muerta de distancia (cm): si el error de pitch (setpoint − distancia)
# es menor que esto en magnitud, fb=0. Evita el vaivén adelante/atrás que el lag
# amplifica cuando el dron oscila alrededor de la distancia objetivo.
FOLLOW_PITCH_DEADBAND_CM = 10.0
# Equivalente para la fuente bbox (error en ratio de altura, no en cm).
FOLLOW_PITCH_DEADBAND_RATIO = 0.05

# Perfil de aproximación (rama métrica cm): limita la velocidad HACIA DELANTE a
# gain·(dist−setpoint) para decelerar y PARARSE en INTERCEPT_DISTANCE_CM en vez de
# embestir (P satura lejos → 50 cm/s constante → overshoot al activar el ToF).
# A margen ≥ FB_MAX/gain (~91 cm con 0.55) el cap no recorta; por debajo, frenada lineal.
FOLLOW_APPROACH_SPEED_GAIN = 0.55   # cm/s de tope por cm de margen sobre el setpoint
# Retirada: el error hacia atrás está acotado (~setpoint) → kp da sólo ~5–13 cm/s.
# Multiplica el fb negativo para una retirada ágil cuando la persona se acerca.
FOLLOW_RETREAT_GAIN_MULTIPLIER = 2.5

# Setpoint de la rama VISIÓN (cm). La visión infravalora la distancia (~40 cm menos
# que el ToF), así que NO se usa el setpoint real (INTERCEPT_DISTANCE_CM) en esta fase:
# el dron frenaría antes de tiempo y al activar el ToF daría un acelerón. Con un setpoint
# más bajo el dron SIGUE acercándose hasta que el ToF (preciso) toma el control y para en
# INTERCEPT_DISTANCE_CM. Si el ToF no llegara nunca, la visión para aquí (red de seguridad).
# BANCO: si el dron se queda corto y el ToF no llega a activarse, BAJARLO; si se acerca
# demasiado en visión pura, SUBIRLO.
VISION_APPROACH_SETPOINT_CM = 35.0

# Límite de variación de fb entre ciclos (unidades RC por frame de vídeo): un
# salto de detección tras un hueco de stream no debe traducirse en un acelerón.
FB_SLEW_RATE_PER_FRAME = 8.0

# Frame
FRAME_W = 640
FRAME_H = 480
FRAME_CENTER_X = FRAME_W // 2
FRAME_CENTER_Y = FRAME_H // 2

# Target vertical setpoint: hombros en 25% desde arribaS
TARGET_Y_RATIO   = 0.25

# Distancia de intercepción (stop ToF): distancia objetivo a la persona.
INTERCEPT_DISTANCE_CM = 60.0

# ToF
FRONT_TOF_WALL_STOP_CM          = 30.0   # pared peligrosa → fb=0
FRONT_TOF_INVALID_HYSTERESIS_FRAMES = 8  # frames sin ToF antes de caer a bbox
FRONT_TOF_DISCONTINUITY_FREEZE_S    = 0.4  # s congelando fb tras salto válido→-1
# Lectura del ToF frontal (RMTT, 'EXT tof?'):
#  - timeout: djitellopy decora Tello con @enforce_types y su firma es
#    send_command_with_return(command: str, timeout: int). Pasar un FLOAT (0.1, 0.4)
#    lanza TypeError ANTES de enviar nada → la lectura SIEMPRE fallaba y front_tof_cm
#    se quedaba en -1.0 (causa real de que el Follow nunca entrara en la rama ToF).
#    DEBE ser un int de segundos. 1 s es el mínimo útil: en éxito el poll interno
#    devuelve en ~0.1 s (no bloquea el segundo entero); 1 s solo acota el fallo.
FRONT_TOF_CMD_TIMEOUT_S         = 1      # int obligatorio (enforce_types)
FRONT_TOF_LOOP_INTERVAL_S       = 0.1    # 10 Hz: con timeout mayor + GPU cargada, 20 Hz solo agrava la contención
FRONT_TOF_LOG_INTERVAL_S        = 1.0    # rate-limit del logging de diagnóstico

# ── Distancia por visión (respaldo/fusión del ToF, a framerate de GPU) ──────
# Estimación métrica pin-hole a partir de la anchura de hombros (keypoints COCO
# 5 y 6): dist_cm = FOCAL_PX * SHOULDER_WIDTH_CM / shoulder_px. Permite que el
# Follow mantenga distancia aunque el ToF físico falle, y se fusiona con él
# (ToF prioritario en corto). FOCAL_PX es parámetro de banco: calibrar comparando
# vision_dist_cm contra el ToF cuando ambos estén disponibles (se loguean juntos).
VISION_DISTANCE_ENABLED   = True
PERSON_SHOULDER_WIDTH_CM  = 40.0   # anchura biacromial media de un adulto
FOCAL_PX                  = 460.0  # focal efectiva del Tello @ FRAME_W=640 (banco)
VISION_MIN_SHOULDER_PX    = 12.0   # por debajo: hombros demasiado juntos/ruidosos → descartar
VISION_DIST_MIN_CM        = 30.0   # recorte de cordura
VISION_DIST_MAX_CM        = 600.0
VISION_DIST_EMA_ALPHA     = 0.40   # suavizado de la distancia por visión

# EMA
# Con GPU + stride 1 las detecciones llegan casi cada frame y dt es ~constante,
# así que el suavizado puede ser más agresivo (menos retraso) sin oscilar. Antes
# 0.25 (necesario para amortiguar el dt variable de la inferencia en CPU).
# BANCO: re-tunear junto a las ganancias PID si el tracking se ve nervioso/lento.
TARGET_EMA_ALPHA    = 0.40

# Detección / tracking
# Inferencia del pose model. POSE_IMGSZ debe coincidir con estacion_tierra.POSE_IMGSZ.
POSE_IMGSZ          = 640   # antes 320; 640 detecta personas más lejanas/pequeñas
# stride 1 = inferencia cada frame. Imprescindible para que el tracker BoT-SORT
# mantenga IDs estables (re-ID) y para que dt del video loop sea ~constante.
# BANCO: subir a 2 sólo si la latencia de inferencia en GPU no da los ~30 FPS.
YOLO_FRAME_STRIDE   = 1
CONF_THRESHOLD      = 0.45
MIN_BBOX_W          = 30
MIN_BBOX_H          = 50

# ── Re-ID persistente (BoT-SORT) ───────────────────────────────────────────
# Tracker de ultralytics: asigna un id estable a cada persona entre frames.
# El follow se ANCLA a un id (self._target_id) y sigue SIEMPRE a esa persona
# aunque haya otras o tras una oclusión breve. Si el id desaparece, NO se salta a
# otra persona (entra en GRACE/SEARCH). El id sólo se libera al entrar en SEARCH.
TRACKER_CFG         = 'botsort.yaml'

# ── Control por gestos (sobre los keypoints del objetivo anclado) ───────────
# Sólo la persona seguida puede comandar. Debounce por frames consecutivos para
# evitar disparos por una detección espuria de keypoints.
GESTURE_CONTROL_ENABLED   = True
GESTURE_CONFIRM_FRAMES    = 5      # frames consecutivos con el gesto para confirmarlo
# Margen vertical (px) que la muñeca debe superar por encima del hombro para
# contar como "brazo arriba". Evita falsos positivos con el brazo a media altura.
GESTURE_WRIST_MARGIN_PX   = 20.0

# Pérdida de objetivo
TARGET_LOST_GRACE_S = 5   # HOVER antes de SEARCH
TRACKING_MISS_HYSTERESIS_FRAMES = 3  # frames dropout que no interrumpen tracking

# Search FSM
SEARCH_SPIN_VELOCITY_DEG_S = 20  # deg/s durante spin
RC_LOOP_INTERVAL_S         = 0.05  # 20 Hz

# Tope de FPS del video loop. Con la GPU potente (RTX) yolo11m-pose @640 corre
# por encima de 30 FPS; subir el tope da más detecciones/seg ⇒ tracking y
# control de distancia más finos. El ToF se desacopla de esta carga (10 Hz,
# timeout holgado) y la distancia por visión actúa como fuente primaria, así que
# más FPS NO depende de una lectura ToF starvada. Los PID son dt-aware (anti-windup),
# pero re-tunear TARGET_EMA_ALPHA/ganancias si el tracking se ve nervioso (banco).
VIDEO_LOOP_TARGET_FPS = 60


# ============================================================
# ORBIT CONTROLLER — constantes
# ============================================================

# Radio objetivo de órbita
ORBIT_RADIUS_CM              = 100.0   # distancia deseada persona-drone
ORBIT_ALIGN_ENTER_CM         = 115.0   # ToF para transición APPROACH → ALIGN
ORBIT_ALIGN_EXIT_CM          = 135.0   # ToF para transición ALIGN → APPROACH
ORBIT_STABLE_TOF_MARGIN_CM   = 8.0     # tolerancia ToF en ALIGN para considerar estable
ORBIT_ALIGN_PX_THRESH        = 30      # píxeles máximos de error yaw en ALIGN
ORBIT_ALIGN_STABLE_FRAMES    = 12      # frames consecutivos estables para entrar en ORBIT
ORBIT_ALIGN_TIMEOUT_S        = 8.0     # timeout máximo en ALIGN antes de reintentar

ORBIT_TANGENTIAL_SPEED       = 24      # lr feedforward base [RC units, 0–100]. Bajado
                                       # 32→24 respecto al original: vuelta más lenta para que el
                                       # yaw (centrado) y el lazo radial sigan a la persona ⇒ menos
                                       # deriva y más suavidad, pero sin quedarse demasiado lento
                                       # (a 18 iba corto). El yaw_ff escala con este valor, así que
                                       # baja con él y se mantiene acoplado. Banco: ajustar al gusto.
ORBIT_LR_MAX_VELOCITY        = 45      # límite lr (feedforward + PID). Da headroom al PID de
                                       # centrado tangencial sobre el feedforward.
ORBIT_RAMP_STEP              = 0.03    # rampa: ~33 ciclos (~1.1s) para máximo lr. Bajado
                                       # 0.06→0.03 para un spool-up más gradual (menos tirón
                                       # al entrar en órbita).
ORBIT_LR_SLEW_RATE_PER_FRAME = 4.0     # límite de variación de lr por frame de vídeo (solo
                                       # Orbit). Evita escalones bruscos de strafe; análogo al
                                       # slew de fb del Follow pero exclusivo de la rama Orbit.
ORBIT_YAW_FF_GAIN            = 0.9     # escala yaw feedforward relativo a lr tangencial. Subido
                                       # 0.7→0.9: menos lag de yaw = el strafe queda más tangente
                                       # y el haz frontal del ToF no pierde a la persona.
ORBIT_RADIAL_FF_GAIN         = 0.10    # feedforward centrípeto (inward/forward) por unidad de lr
                                       # tangencial. Compensa la fuga geométrica hacia afuera del
                                       # strafe+yaw sin esperar al PID radial. Bajado 0.25→0.10: con
                                       # el ToF cerrando el lazo radial de forma fiable, un FF alto
                                       # SESGABA hacia dentro y el dron se acercaba demasiado.
                                       # Banco: subir si deriva hacia afuera; bajar si hacia adentro.
ORBIT_MAX_RADIUS_CM          = 170.0   # (legacy) ToF máx absoluto; sustituido por radio+drift
ORBIT_LOST_FRAMES            = 6       # frames consecutivos sin target → estado 'lost'
ORBIT_LOST_GRACE_S           = 3.0     # gracia en 'lost' antes de 'search'
ORBIT_WALL_STOP_CM           = 35.0    # wall stop específico de Orbit (más conservador)

# Radio automático: el Orbit captura (latch) la distancia ToF actual a la persona como
# radio, en vez de un valor de slider. El FollowController es nuevo en cada activación, así
# que el ToF aún no ha leído nada al activar → el latch se hace en la FSM (estado 'search')
# en la primera lectura válida.
ORBIT_RADIUS_LATCH_TIMEOUT_S = 2.0     # espera máx. de ToF válido antes de usar el fallback
ORBIT_RADIUS_MIN_CM          = 45.0    # suelo del radio auto: solo recorte de cordura por encima
                                       # del wall-stop (35cm). El Orbit mantiene la distancia REAL
                                       # a la que empieza a orbitar; este mínimo solo evita fijar un
                                       # radio por debajo del freno anti-choque.
ORBIT_RADIUS_MAX_CM          = 160.0   # recorte de cordura (dentro del rango fiable del ToF)
ORBIT_MAX_DRIFT_CM           = 70.0    # margen sobre el radio para volver a APPROACH
ORBIT_ALIGN_ENTER_MARGIN_CM  = 15.0    # margen relativo al radio para APPROACH → ALIGN

# Closeness setpoint para Orbit (bbox fallback cuando no hay ToF)
# Radio 100cm ≈ bbox_height_ratio ~0.55 en Tello con persona adulta
ORBIT_CLOSENESS_SETPOINT = 0.55

# ── Mantener distancia en estado 'orbit' (ToF primario) ──────────────────────
# En vuelo real el ToF del dron resultó fiable y responsivo (lecturas limpias de
# 20–100cm), así que es la SEÑAL RADIAL PRIMARIA: es métrica y, sobre todo, es la
# única que detecta "demasiado cerca" (el bbox closeness SATURA a ~1.0 cuando la
# persona llena el frame y deja de medir la proximidad). El closeness queda solo de
# respaldo (orbit_dist_cm cae a la rama bbox→cm si el ToF no responde un rato).
ORBIT_RADIAL_DEADBAND_CM     = 10.0    # banda muerta del error de distancia (cm): dentro de
                                       # ella fb=0, para no temblar al mantener el radio.
ORBIT_FB_SLEW_RATE_PER_FRAME = 5.0     # límite de variación de fb por frame (solo Orbit).
                                       # Suaviza los saltos cuando el haz del ToF parpadea
                                       # (p.ej. lee el fondo un frame) y evita tirones de pitch.
ORBIT_DIST_EMA_ALPHA         = 0.40    # suavizado de la distancia radial (orbit-only) antes de
                                       # alimentar el lazo. El pitch PID es COMPARTIDO con Follow
                                       # (no se puede retunear), así que se filtra la ENTRADA:
                                       # reduce el "chase" del ToF ruidoso ⇒ radio más fijo, menos
                                       # vaivén in/out y menos cruces del wall-stop.


class FollowController:
    """
    Modo Follow migrado del proyecto de referencia (tello_interceptor.py).
    FSM: INTERCEPTING → HOVER (grace) → SEARCHING (spin 360°)
    Pitch dual: ToF (prioritario) / bbox_ratio (fallback).
    Arquitectura de hilos conservada (vid_thread, rc_thread, tof_thread).
    """

    def __init__(self, tello_ref, pose_model=None):
        self._tello = tello_ref
        self._active = True
        self.on_stream_dead = None  # callable() — llamado cuando el stream de vídeo muere

        # Modelo de poses YOLO. Se INYECTA desde estacion_tierra para NO hacer
        # `from estacion_tierra import pose_model` aquí: la ET se ejecuta como
        # `__main__`, así que ese import re-ejecutaría todo el fichero como un
        # módulo nuevo y se quedaría colgado en su `threading.Event().wait()`
        # final, congelando el _video_loop en la primera detección (el dron
        # giraba sin detectar nunca). Fallback robusto vía sys.modules por si se
        # construye sin pasar el modelo.
        if pose_model is None:
            import sys
            _mm = sys.modules.get('__main__')
            if _mm is None or not hasattr(_mm, 'pose_model'):
                _mm = sys.modules.get('estacion_tierra')
            pose_model = getattr(_mm, 'pose_model', None) if _mm else None
        self._pose_model = pose_model

        # ── SDK lock unificado ──
        # Compartido con el resto de accesos al socket de comandos del Tello
        # (telemetría wifi?, stream_on/off, _send, flip). Se usa el lock que vive
        # en la instancia TelloDron para que tof? no cruce respuestas con esos
        # hilos. Fallback a un Lock propio si por algún motivo no existiera.
        self._sdk_lock = getattr(tello_ref, '_sdk_lock', None) or threading.RLock()

        # ── RC ────────────────────────────────────────────────────────
        self._rc_lock = threading.Lock()
        self._rc = [0, 0, 0, 0]   # lr, fb, ud, yaw

        # ── PIDs (proyecto referencia) ────────────────────────────────
        self.yaw_pid   = PIDController(*GAINS_YAW_PID,
                                       output_min=-YAW_MAX_VELOCITY,
                                       output_max=YAW_MAX_VELOCITY)
        self.altitude_pid = PIDController(*GAINS_ALTITUDE_PID,
                                          output_min=-UD_MAX_VELOCITY,
                                          output_max=UD_MAX_VELOCITY)
        self.pitch_pid     = PIDController(*GAINS_FORWARD_BACK_TOF_PID,
                                           output_min=-FB_MAX_VELOCITY,
                                           output_max=FB_MAX_VELOCITY)
        self.pitch_bbox_pid = PIDController(*GAINS_FORWARD_BACK_BBOX_PID,
                                            output_min=-FB_MAX_VELOCITY,
                                            output_max=FB_MAX_VELOCITY)
        # fb del ciclo anterior, para el limitador de slew-rate del Follow.
        self._fb_prev: float = 0.0

        # ── EMA ───────────────────────────────────────────────────────
        self._target_smoothed_x_px:  float = 0.0
        self._target_smoothed_y_px:  float = 0.0
        self._target_ema_initialized: bool  = False
        self._closeness_smoothed:    float = 0.0
        self._closeness_ema_initialized: bool = False

        # ── Pitch source (D-term seeding en transición) ───────────────
        self._pitch_source_last: str = 'none'

        # ── ToF ───────────────────────────────────────────────────────
        self._tof_lock          = threading.Lock()
        self.front_tof_cm:  float = -1.0
        self._tof_cm_prev:  float = -1.0
        self._tof_invalid_count:  int   = 0
        self._last_valid_front_tof_cm: float = -1.0
        self._front_tof_freeze_until:  float = 0.0
        # Salud del ToF (diagnóstico): contadores y rate-limit del logging.
        self._tof_ok_count:    int   = 0
        self._tof_fail_count:  int   = 0
        self._tof_last_log_t:  float = 0.0

        # ── Distancia por visión (respaldo/fusión del ToF) ────────────
        self._vision_dist_cm:        float = -1.0   # última estimación cruda válida
        self._vision_dist_smoothed:  float = 0.0
        self._vision_dist_initialized: bool = False

        # ── Hysteresis de detección ───────────────────────────────────
        self._tracking_miss_count: int = 0

        # ── Re-ID (BoT-SORT): id del objetivo anclado ─────────────────
        # Se fija al adquirir objetivo y sólo se libera al entrar en SEARCH
        # (objetivo definitivamente perdido). Sólo aplica en Follow, no en Orbit.
        self._target_id = None   # int | None

        # ── Gestos del objetivo ───────────────────────────────────────
        self._gesture           = None   # gesto confirmado ('both_up'|'left_up'|'right_up'|None)
        self._gesture_candidate = None   # gesto en proceso de confirmación
        self._gesture_count     = 0      # frames consecutivos del candidato
        self._gesture_paused    = False  # follow en pausa (hover) por gesto both_up

        # ── Pérdida / search ──────────────────────────────────────────
        self._last_target_seen_time:  float = 0.0
        self._last_target_side:       int   = 0   # -1 izq, +1 der, 0 centro
        self._search_state:           str   = 'none'   # 'none' | 'spin'
        self._search_spin_angle_deg:  float = 0.0
        self._search_spin_start_t:    float = 0.0   # time.time() de inicio del spin


        #-----------------------

        # ── ORBIT MODE ────────────────────────────────────────────────────────
        # Flag principal. True = el _video_loop ejecuta FSM de Orbit en lugar de Follow.
        self._orbit_mode: bool = False

        # Dirección de órbita: +1 = clockwise (lr positivo), -1 = CCW
        self._orbit_sign: int = 1

        # FSM del Orbit (6 estados)
        # 'search' | 'approach' | 'align' | 'orbit' | 'lost' | 'hover_safe'
        self._orbit_state: str = 'search'

        # PID tangencial: error de centrado horizontal → velocidad lr
        # Ganancias conservadoras para órbita suave
        self.tangential_pid = PIDController(
            0.08, 0.001, 0.02,
            output_min=-ORBIT_LR_MAX_VELOCITY,
            output_max=ORBIT_LR_MAX_VELOCITY,
        )

        # Velocidad tangencial feedforward (lr base durante órbita)
        # El PID corrige sobre este feedforward
        self._orbit_tangential_ff: int = ORBIT_TANGENTIAL_SPEED

        # Rampa de entrada al Orbit (evita spike en lr al activar)
        self._orbit_ramp: float = 0.0

        # lr/fb del ciclo anterior, para los limitadores de slew-rate del Orbit.
        self._orbit_lr_prev: float = 0.0
        self._orbit_fb_prev: float = 0.0

        # EMA de la distancia radial (orbit-only) para el lazo de mantenimiento de radio.
        self._orbit_dist_smoothed: float = 0.0
        self._orbit_dist_initialized: bool = False

        # Radio objetivo de órbita en cm. En modo auto se latchea a la distancia ToF
        # actual en el estado 'search'; ORBIT_RADIUS_CM es el valor por defecto/fallback.
        self._orbit_radius_cm: float = ORBIT_RADIUS_CM
        self._orbit_radius_latched: bool = False    # ¿ya se fijó el radio esta activación?
        self._orbit_search_start_time: float = 0.0  # t0 para el timeout de latch del radio

        # Contador de frames consecutivos sin target durante Orbit
        self._orbit_lost_count: int = 0

        # Tiempo de entrada en estado 'align' (para timeout de alineación)
        self._orbit_align_start_time: float = 0.0

        self._orbit_align_stable_count: int = 0

        # Timestamp de entrada en estado 'lost' (para grace period de Orbit)
        self._orbit_lost_start_time: float = 0.0

        # Status exportable para telemetría (igual que _follow_status)
        self._orbit_status: str = 'waiting'

        # ToF display para telemetría de Orbit
        self._orbit_tof_display: float = -1.0




        #-----------------------

        # ── Frame debug ───────────────────────────────────────────────
        self._frame_lock   = threading.Lock()
        self._debug_frame  = None
        self._debug_frame_ts = 0.0   # time.time() del último _debug_frame escrito

        # ── Telemetría ────────────────────────────────────────────────
        self._follow_status: str   = 'waiting'
        self._tof_display:   float = -1.0

        # ── Hilos ─────────────────────────────────────────────────────
        self._tof_thread = threading.Thread(target=self._tof_loop, daemon=True)
        self._tof_thread.start()

        self._rc_thread = threading.Thread(target=self._rc_loop, daemon=True)
        self._rc_thread.start()

        self._vid_thread = threading.Thread(target=self._video_loop, daemon=True)
        self._vid_thread.start()

    # ------------------------------------------------------------------ ToF loop
    def _tof_loop(self):
        while self._active:
            err_kind = None   # None | 'no_inner' | 'exc:<tipo>' | 'no_response' | 'no_match'
            raw = None
            ok_cm = None      # cm parseado en este ciclo (para logging de éxito)
            try:
                # Guard: si el Tello perdió WiFi y disconnect() (otro hilo) puso
                # _tello._tello a None, no acceder al socket (evita AttributeError
                # silenciado en bucle sin backoff).
                inner = getattr(self._tello, '_tello', None)
                if inner is None:
                    err_kind = 'no_inner'
                    time.sleep(FRONT_TOF_LOOP_INTERVAL_S)
                    continue
                with self._sdk_lock:
                    # Vaciar la cola `responses` ANTES de enviar: djitellopy la
                    # comparte entre todos los comandos con respuesta (wifi?, etc.).
                    # Si quedó un datagrama rezagado de otro comando, send_command_
                    # with_return haría pop de ESE (cross-talk) en vez de la respuesta
                    # del 'EXT tof?'. Limpiarla bajo el lock garantiza leer lo nuestro.
                    try:
                        inner.get_own_udp_object()['responses'].clear()
                    except Exception:
                        pass
                    # timeout holgado: 0.1 s expiraba bajo la carga de YOLO/WiFi y
                    # el ToF nunca se actualizaba (causa de que el Follow no entrara
                    # en la rama ToF). Ver FRONT_TOF_CMD_TIMEOUT_S.
                    # timeout DEBE ser int (enforce_types de djitellopy); int() lo
                    # garantiza aunque alguien cambie la constante a float.
                    raw = inner.send_command_with_return(
                        'EXT tof?', timeout=int(FRONT_TOF_CMD_TIMEOUT_S))
                mm = self._parse_tof_mm(raw)
                if mm is None:
                    err_kind = 'no_response' if not raw else 'no_match'
                    self._tof_fail_count += 1
                else:
                    self._tof_ok_count += 1
                    new_cm = -1.0 if mm >= 8190 else mm / 10.0
                    ok_cm = new_cm
                    # _tof_cm_prev y _front_tof_freeze_until se comparten con
                    # _video_loop_inner: agruparlos bajo _tof_lock junto a la
                    # secuencia read-compare-write de la guardia diagonal.
                    with self._tof_lock:
                        # Guardia diagonal: válido→-1 = drone pasó borde de pared
                        if self._tof_cm_prev > 0 and new_cm == -1.0:
                            self._front_tof_freeze_until = time.time() + FRONT_TOF_DISCONTINUITY_FREEZE_S
                        self._tof_cm_prev = new_cm
                        self.front_tof_cm = new_cm
            except Exception as e:
                err_kind = f'exc:{type(e).__name__}'
                self._tof_fail_count += 1
            # ── Diagnóstico rate-limited (~1/s) ───────────────────────────────
            # Se loguea TANTO el fallo (por qué no hay lectura) COMO el éxito (qué
            # valor real llega): sin loguear el éxito era imposible saber si los
            # 'ok' eran lecturas reales, timeouts mal parseados o cross-talk.
            t = time.time()
            if t - self._tof_last_log_t >= FRONT_TOF_LOG_INTERVAL_S:
                self._tof_last_log_t = t
                if err_kind is not None:
                    print(f'[FOLLOW][ToF] sin lectura ({err_kind}) '
                          f'raw={raw!r} ok={self._tof_ok_count} fail={self._tof_fail_count}')
                else:
                    print(f'[FOLLOW][ToF] OK {ok_cm:.1f}cm raw={raw!r} '
                          f'ok={self._tof_ok_count} fail={self._tof_fail_count}')
            # 10 Hz: con el timeout holgado y la GPU cargada, insistir más rápido
            # solo agrava la contención. La visión es la fuente primaria de distancia.
            time.sleep(FRONT_TOF_LOOP_INTERVAL_S)

    @staticmethod
    def _parse_tof_mm(raw):
        """Extrae los mm de la respuesta de 'EXT tof?'. Acepta SÓLO una lectura real
        'tof <mm>' (p.ej. 'tof 1234', 'tof1234', 'tof:1234'); devuelve None en
        cualquier otro caso.

        ⚠ NO usar un `\\d+` suelto: djitellopy, al expirar el timeout, devuelve el
        string 'Aborting command \\'EXT tof?\\'. Did not receive a response after 1
        seconds' — un `\\d+` casaría el '1' de "after 1 seconds" y contaría cada
        TIMEOUT como una lectura válida de 1 mm (0.1 cm). Igual de peligroso es el
        cross-talk: la cola `responses` de djitellopy es compartida, así que un
        número suelto de un 'wifi?'/'battery?' del hilo de telemetría podría colarse.
        Exigir el token 'tof' SEGUIDO del número descarta ambos: el mensaje de
        timeout contiene 'tof?'' (un '?' tras 'tof', no un dígito) y los números de
        cross-talk no llevan 'tof' delante. 'unknown command: tof' tampoco casa
        (no hay dígito tras 'tof')."""
        if not raw:
            return None
        s = raw.decode('utf-8', 'ignore') if isinstance(raw, (bytes, bytearray)) else str(raw)
        m = re.search(r'tof[\s:]*(\d+)', s, re.IGNORECASE)
        return int(m.group(1)) if m else None

    # ------------------------------------------------------------------ RC loop
    def _rc_loop(self):
        fail_count = 0
        while self._active:
            t0 = time.time()
            with self._rc_lock:
                lr, fb, ud, yaw = self._rc
            try:
                # rc → send_rc_control (sin respuesta): no toca la cola `responses`
                # y NO debe tomar _sdk_lock, o el bucle a 20 Hz se bloquearía detrás
                # de un tof?/wifi? en espera.
                self._tello.rc(lr, fb, ud, yaw)
                fail_count = 0
            except Exception as e:
                fail_count += 1
                print(f'[FOLLOW] rc error: {e}')
                # Fallo persistente (p.ej. WiFi caído durante una órbita con lr!=0):
                # detener el controller en vez de seguir a 20 Hz sin efecto y
                # depender del watchdog del Tello (~1s). El _video_loop notificará
                # on_stream_dead al detectar el stream muerto.
                if fail_count >= 3:
                    print('[FOLLOW] rc fallo persistente, deteniendo controller.')
                    with self._rc_lock:
                        self._rc = [0, 0, 0, 0]
                    self._active = False
                    break
            elapsed = time.time() - t0
            time.sleep(max(0.0, RC_LOOP_INTERVAL_S - elapsed))

    # ------------------------------------------------------------------ Detección YOLO
    def _detect_persons(self, frame_bgr, frame_w=FRAME_W, frame_h=FRAME_H):
        """Retorna lista de (x1,y1,x2,y2, shoulder_cy_or_None, track_id_or_None,
        kp_xy_or_None).

        Usa pose_model.track() con persist=True: BoT-SORT asigna un id estable a
        cada persona entre frames consecutivos (re-ID). track_id permite anclar el
        follow a UNA persona; kp_xy (keypoints [x,y]) alimenta el control por gestos.

        IMPORTANTE: ultralytics asume que un array numpy viene en BGR (convención
        cv2) y lo invierte internamente a RGB antes de inferir. djitellopy entrega
        los frames en RGB, así que aquí se debe pasar la versión ya convertida a
        BGR (frame_bgr); pasar el RGB crudo intercambia R/B y la detección falla.
        """
        pose_model = self._pose_model
        if pose_model is None:
            raise RuntimeError('pose_model no inyectado en FollowController')
        # persist=True conserva el estado del tracker entre llamadas (requiere
        # frames consecutivos → stride 1). classes=[0]: sólo personas.
        results = pose_model.track(frame_bgr, imgsz=POSE_IMGSZ, persist=True,
                                   classes=[0], tracker=TRACKER_CFG, verbose=False)
        persons = []
        for result in results:
            if result.boxes is None:
                continue
            kps = result.keypoints.xy if result.keypoints is not None else None
            ids = (result.boxes.id.int().cpu().tolist()
                   if result.boxes.id is not None else None)
            for i, (box, conf) in enumerate(zip(result.boxes.xyxy, result.boxes.conf)):
                if float(conf) < CONF_THRESHOLD:
                    continue
                x1 = max(0, int(box[0]))
                y1 = max(0, int(box[1]))
                x2 = min(int(box[2]), frame_w)
                y2 = min(int(box[3]), frame_h)
                if (x2 - x1) < MIN_BBOX_W or (y2 - y1) < MIN_BBOX_H:
                    continue
                kp_xy = None
                shoulder_cy = None
                if kps is not None and len(kps) > i:
                    kp = kps[i]
                    # numpy para el detector de gestos (independiente de torch)
                    kp_xy = kp.cpu().numpy() if hasattr(kp, 'cpu') else np.asarray(kp)
                    if len(kp) > 6:
                        lsx, lsy = float(kp[5][0]), float(kp[5][1])
                        rsx, rsy = float(kp[6][0]), float(kp[6][1])
                        if lsx > 0 and rsx > 0:
                            shoulder_cy = (lsy + rsy) / 2.0
                track_id = ids[i] if (ids is not None and len(ids) > i) else None
                persons.append((x1, y1, x2, y2, shoulder_cy, track_id, kp_xy))
        return persons

    def _select_best_person(self, persons, last_point_px, target_id=None):
        """
        Selección con re-ID (BoT-SORT):
        - Si hay objetivo anclado (target_id) y sigue presente → ESA persona
          (no se salta a otra aunque haya varias o pasen por delante).
        - Si target_id está anclado pero NO aparece este frame → None (miss): lo
          gestiona la histéresis/GRACE, evitando perseguir a otra persona.
        - Sin ancla (target_id None): comportamiento previo — last_point_px → más
          cercana en píxeles; si no hay → mayor área bbox.
        p = (x1,y1,x2,y2, shoulder_cy, track_id, kp_xy); p[5] = track_id.
        """
        if not persons:
            return None
        if target_id is not None:
            for p in persons:
                if p[5] == target_id:
                    return p
            return None
        if last_point_px is None:
            return max(persons, key=lambda p: (p[2]-p[0]) * (p[3]-p[1]))
        lx, ly = last_point_px
        return min(persons, key=lambda p: ((p[0]+p[2])/2 - lx)**2 + ((p[1]+p[3])/2 - ly)**2)

    # ------------------------------------------------------------ Distancia visión
    @staticmethod
    def _estimate_distance_cm(kp_xy):
        """Distancia métrica estimada (cm) por modelo pin-hole usando la anchura de
        hombros (keypoints COCO 5 y 6): dist = FOCAL_PX * SHOULDER_WIDTH_CM / px.
        Respaldo/fusión del ToF físico, calculable cada frame en GPU. Devuelve None
        si los hombros no son fiables (persona de lado, keypoints en (0,0), etc.)."""
        if kp_xy is None or len(kp_xy) <= 6:
            return None
        lsx, lsy = float(kp_xy[5][0]), float(kp_xy[5][1])
        rsx, rsy = float(kp_xy[6][0]), float(kp_xy[6][1])
        # (0,0) = keypoint no detectado en ultralytics
        if lsx <= 0 or rsx <= 0:
            return None
        shoulder_px = ((lsx - rsx) ** 2 + (lsy - rsy) ** 2) ** 0.5
        if shoulder_px < VISION_MIN_SHOULDER_PX:
            return None
        dist = FOCAL_PX * PERSON_SHOULDER_WIDTH_CM / shoulder_px
        if dist < VISION_DIST_MIN_CM or dist > VISION_DIST_MAX_CM:
            return None
        return dist

    # ------------------------------------------------------------ Shaping pitch
    @staticmethod
    def _shape_pitch_fb(fb: float, dist_cm: float,
                        setpoint_cm: float = INTERCEPT_DISTANCE_CM) -> float:
        """Da forma al fb de la rama métrica: cap de aproximación (decelerar/parar en
        el setpoint, evita overshoot) + boost de retirada (retroceso ágil)."""
        if fb > 0:
            cap = max(0.0, FOLLOW_APPROACH_SPEED_GAIN * (dist_cm - setpoint_cm))
            return min(fb, cap)
        if fb < 0:
            return max(fb * FOLLOW_RETREAT_GAIN_MULTIPLIER, -FB_MAX_VELOCITY)
        return fb

    # ------------------------------------------------------------------ Gestos
    def _detect_gesture(self, kp_xy):
        """Devuelve 'both_up' | 'left_up' | 'right_up' | None según los keypoints
        del objetivo. 'arriba' = muñeca por encima del hombro (eje y hacia abajo)
        con margen GESTURE_WRIST_MARGIN_PX. left/right son del lado de la IMAGEN.
        Keypoints COCO: 5 hombro-izq, 6 hombro-der, 9 muñeca-izq, 10 muñeca-der.
        """
        if kp_xy is None or len(kp_xy) <= 10:
            return None

        def _up(wrist_idx, shoulder_idx):
            wx, wy = float(kp_xy[wrist_idx][0]), float(kp_xy[wrist_idx][1])
            sx, sy = float(kp_xy[shoulder_idx][0]), float(kp_xy[shoulder_idx][1])
            # (0,0) = keypoint no visible → no contar como brazo arriba
            if wx <= 0 or wy <= 0 or sx <= 0 or sy <= 0:
                return False
            return wy < (sy - GESTURE_WRIST_MARGIN_PX)

        left_up  = _up(9, 5)
        right_up = _up(10, 6)
        if left_up and right_up:
            return 'both_up'
        if left_up:
            return 'left_up'
        if right_up:
            return 'right_up'
        return None

    def _reset_gesture_state(self):
        self._gesture           = None
        self._gesture_candidate = None
        self._gesture_count     = 0
        self._gesture_paused    = False

    # ------------------------------------------------------------------ Vídeo loop principal
    def _video_loop(self):
        """Wrapper robusto: si el bucle interno lanza una excepción, la registra
        y reanuda en vez de morir en silencio (lo que dejaría el modo atascado)."""
        import traceback
        while self._active:
            try:
                self._video_loop_inner()
            except Exception:
                print('[FOLLOW] excepcion en _video_loop:')
                traceback.print_exc()
                time.sleep(0.1)

    def _video_loop_inner(self):
        frame_count        = 0
        consecutive_none   = 0
        detected_persons   = []
        prev_t             = time.time()
        # ── FPS / latencia (B3): validar el salto CPU 320 → GPU 640 y tunear stride ──
        _fps_t0            = time.time()
        _fps_frames        = 0
        _fps_last          = 0.0

        while self._active:
            frame_rgb = self._tello.get_frame()

            if frame_rgb is None:
                consecutive_none += 1
                if consecutive_none > 300:
                    print('[FOLLOW] Stream muerto, deteniendo.')
                    # Neutralizar RC antes de matar el loop: si el último RC tenía
                    # yaw/lr de búsqueda o tangencial, el _rc_loop seguiría
                    # enviándolo hasta que el watchdog del Tello (~1s) lo corte.
                    try:
                        self._tello.rc(0, 0, 0, 0)
                    except Exception:
                        pass
                    with self._rc_lock:
                        self._rc = [0, 0, 0, 0]
                    self._active = False
                    if callable(self.on_stream_dead):
                        self.on_stream_dead()
                    break
                time.sleep(0.01)
                continue
            consecutive_none = 0

            frame_count += 1
            frame_bgr = cv2.cvtColor(frame_rgb, cv2.COLOR_RGB2BGR)
            actual_h, actual_w = frame_bgr.shape[:2]
            frame_center_x = actual_w // 2

            _now_t = time.time()
            dt = max(0.01, min(_now_t - prev_t, 0.2))
            prev_t = _now_t

            # Snapshot único de _orbit_mode por frame: activate_orbit/
            # deactivate_orbit corren en el hilo MQTT y escriben _orbit_mode el
            # último (GIL → todo el estado de Orbit ya es coherente cuando se ve
            # True). Capturarlo una sola vez (aquí, antes de la selección) evita
            # que un cambio se intercale y ejecute Follow y Orbit en el mismo frame.
            orbit_mode = self._orbit_mode

            # Setpoint vertical: hombros al 25% superior del frame
            target_setpoint_y_px = int(actual_h * TARGET_Y_RATIO)

            # ── Detección YOLO (cada STRIDE frames) ─────────────────
            if frame_count % YOLO_FRAME_STRIDE == 0:
                try:
                    detected_persons = self._detect_persons(frame_bgr, actual_w, actual_h)
                except Exception as e:
                    print(f'[FOLLOW] error deteccion YOLO: {e}')
                    # Limpiar: si no se vacía, _select_best_person devolvería el
                    # objetivo del stride anterior y el dron perseguiría un
                    # fantasma congelado sin entrar nunca en GRACE/SEARCH.
                    detected_persons = []

            # ── Selección del mejor objetivo ────────────────────────
            last_point = (
                (self._target_smoothed_x_px, self._target_smoothed_y_px)
                if self._target_ema_initialized else None
            )
            # Re-ID sólo en Follow: en Orbit pasamos target_id=None para conservar
            # exactamente la lógica de recuperación de la FSM de Orbit.
            target_for_sel = self._target_id if not orbit_mode else None
            best = self._select_best_person(detected_persons, last_point, target_for_sel)
            now  = time.time()

            # ── Punto de tracking raw ────────────────────────────────
            tracking_target_raw = False
            target_x_px = None
            target_y_px = None
            tracked_shoulder_cy = None
            tracked_kp = None

            if best is not None:
                x1, y1, x2, y2, shoulder_cy, track_id, kp_xy = best
                bw = x2 - x1
                bh = y2 - y1
                # X: centro bbox; Y: hombros si visible, si no centro bbox
                raw_cx = float(x1 + bw / 2.0)
                raw_cy = shoulder_cy if shoulder_cy is not None else float(y1 + bh / 2.0)
                target_x_px = int(raw_cx)
                target_y_px = int(raw_cy)
                tracked_shoulder_cy = shoulder_cy
                tracked_kp = kp_xy
                tracking_target_raw = True
                # Re-ID (sólo Follow): anclar el id la primera vez que adquirimos
                # objetivo. A partir de aquí _select_best_person sólo devuelve esta
                # persona; si desaparece, NO se salta a otra (entra en GRACE/SEARCH).
                if not orbit_mode and self._target_id is None and track_id is not None:
                    self._target_id = track_id
                    print(f'[FOLLOW] objetivo anclado id={track_id}')

            # ── Hysteresis de detección ──
            if tracking_target_raw:
                self._tracking_miss_count = 0
                tracking_target = True
            else:
                self._tracking_miss_count += 1
                tracking_target = (
                    self._tracking_miss_count <= TRACKING_MISS_HYSTERESIS_FRAMES
                    and self._target_ema_initialized
                )

            # ── Estado de seguimiento (común a Follow y Orbit) ───────
            # Lado y EMA de posición del objetivo. DEBEN mantenerse en AMBOS modos:
            # el Orbit reutiliza _last_target_side para el sentido de búsqueda y
            # _target_smoothed_x_px para el centrado de yaw. Antes vivían sólo en la
            # rama Follow (INTERCEPTING, gated por `not orbit_mode`) → en Orbit
            # quedaban congelados y el search giraba hacia el lado equivocado.
            if tracking_target_raw:
                # Lado: persona a la derecha (side>0) → +1; a la izquierda → -1.
                # yaw>0 (SDK) = giro horario = hacia la derecha, así el search gira
                # HACIA el último lado donde se vio a la persona.
                side = target_x_px - frame_center_x
                if side > 0:
                    self._last_target_side = 1
                elif side < 0:
                    self._last_target_side = -1
                # EMA posición target (init + suavizado)
                if not self._target_ema_initialized:
                    self._target_smoothed_x_px = float(target_x_px)
                    self._target_smoothed_y_px = float(target_y_px)
                    self._target_ema_initialized = True
                else:
                    a = TARGET_EMA_ALPHA
                    self._target_smoothed_x_px = (a * target_x_px +
                                                   (1 - a) * self._target_smoothed_x_px)
                    self._target_smoothed_y_px = (a * target_y_px +
                                                   (1 - a) * self._target_smoothed_y_px)

            # ── Gestos del objetivo anclado ──────────────────────────
            # Sólo la persona seguida comanda. Debounce: el gesto debe repetirse
            # GESTURE_CONFIRM_FRAMES frames seguidos para confirmarse (evita
            # disparos por keypoints espurios). Mapeo (ampliable):
            #   both_up → pausa (hover) mientras se mantenga.
            if GESTURE_CONTROL_ENABLED and not orbit_mode:
                g = self._detect_gesture(tracked_kp) if tracking_target_raw else None
                if g == self._gesture_candidate:
                    self._gesture_count += 1
                else:
                    self._gesture_candidate = g
                    self._gesture_count = 1
                if self._gesture_count >= GESTURE_CONFIRM_FRAMES:
                    self._gesture = g
                self._gesture_paused = (self._gesture == 'both_up')

            # ── ToF: lectura thread-safe ─────────────────────────────
            with self._tof_lock:
                current_tof_cm = self.front_tof_cm

            valid_front_tof = current_tof_cm > 0

            # ── ToF hysteresis ───────
            if valid_front_tof:
                self._tof_invalid_count = 0
                self._last_valid_front_tof_cm = current_tof_cm
            else:
                self._tof_invalid_count += 1

            # ── FSM principal ────────────────────────────────────────
            lr  = 0
            fb  = 0
            ud  = 0
            yaw = 0
            pitch_source = 'none'

            # ────────────────────────────────────────────────────────
            # INTERCEPTING
            # ────────────────────────────────────────────────────────
            if not orbit_mode and tracking_target:
                if tracking_target_raw:
                    self._last_target_seen_time = now
                    # (el lado del target y la EMA de posición se actualizan ahora en
                    # la sección común por-frame, válida también para Orbit)

                self._search_state = 'none'
                self._follow_status = 'intercepting'

                # ── Pausa por gesto (ambos brazos arriba) ────────────
                # Mantiene el objetivo anclado y la EMA, pero detiene el control:
                # hover neutral mientras la persona seguida tenga ambos brazos
                # arriba. Suelta los integrales y no acumula dt durante la pausa.
                if self._gesture_paused:
                    self._follow_status = 'paused'
                    self._tof_display = -1.0
                    self.yaw_pid.reset_integral()
                    self.altitude_pid.reset_integral()
                    self.pitch_pid.reset_integral()
                    self.pitch_bbox_pid.reset_integral()
                    with self._rc_lock:
                        self._rc = [0, 0, 0, 0]
                    self._fb_prev = 0.0
                    prev_t = time.time()   # no acumular dt durante la pausa
                    time.sleep(0.01)
                    continue

                # (EMA de posición del target: ahora en la sección común por-frame)

                # EMA closeness (bbox_height_ratio, igual que proyecto referencia)
                if tracking_target_raw and best is not None:
                    x1, y1, x2, y2, *_ = best
                    raw_closeness = (y2 - y1) / float(actual_h)
                    if not self._closeness_ema_initialized:
                        self._closeness_smoothed = raw_closeness
                        self._closeness_ema_initialized = True
                    else:
                        self._closeness_smoothed = (TARGET_EMA_ALPHA * raw_closeness +
                                                    (1 - TARGET_EMA_ALPHA) * self._closeness_smoothed)

                # EMA distancia por visión (cm) desde keypoints de hombros. Sirve de
                # respaldo/fusión del ToF físico y se calcula a framerate de GPU.
                if VISION_DISTANCE_ENABLED and tracking_target_raw:
                    vdist = self._estimate_distance_cm(tracked_kp)
                    if vdist is not None:
                        self._vision_dist_cm = vdist
                        if not self._vision_dist_initialized:
                            self._vision_dist_smoothed = vdist
                            self._vision_dist_initialized = True
                        else:
                            self._vision_dist_smoothed = (
                                VISION_DIST_EMA_ALPHA * vdist +
                                (1 - VISION_DIST_EMA_ALPHA) * self._vision_dist_smoothed)

                # ── Altitud PID ──────────────────────────────────────
                error_altitude = self._target_smoothed_y_px - target_setpoint_y_px
                ud = self.altitude_pid.compute(error_altitude, dt)

                # ── Yaw PID ──────────────────────────────────────────
                error_yaw = self._target_smoothed_x_px - frame_center_x
                yaw = self.yaw_pid.compute(error_yaw, dt)

                # ── Pitch PID (distancia en cm: ToF físico → visión → bbox) ──
                # Fuente 1: ToF físico (más preciso en corto). Hysteresis igual
                # que el proyecto de referencia.
                # Fuente 2: distancia por visión (cm) cuando el ToF no responde —
                # mismo PID y mismo setpoint, así el Follow mantiene distancia
                # aunque el ToF físico falle. Ambas son 'cm' → transición suave.
                # Fuente 3: ratio de bbox (adimensional) como último recurso.
                _tof_available = (self._last_valid_front_tof_cm > 0 and
                                  self._tof_invalid_count < FRONT_TOF_INVALID_HYSTERESIS_FRAMES)
                if _tof_available:
                    pitch_source = 'tof'
                    dist_for_pid = (current_tof_cm if valid_front_tof
                                    else self._last_valid_front_tof_cm)
                    error_pitch = INTERCEPT_DISTANCE_CM - dist_for_pid
                    # Sembrar error_last al entrar desde otra fuente → evita spike
                    # D-term. tof y tof_vision usan setpoints distintos (la visión
                    # infravalora), así que también se resiembra al cruzar entre ellas.
                    if self._pitch_source_last != 'tof':
                        self.pitch_pid.error_last = error_pitch
                    fb = self.pitch_pid.compute(error_pitch, dt)
                    if abs(error_pitch) < FOLLOW_PITCH_DEADBAND_CM:
                        fb = 0.0
                    fb = self._shape_pitch_fb(fb, dist_for_pid)
                    self.pitch_bbox_pid.reset_integral()
                    self._follow_status = 'tof'
                    self._tof_display = dist_for_pid

                elif VISION_DISTANCE_ENABLED and self._vision_dist_initialized:
                    pitch_source = 'tof_vision'
                    dist_for_pid = self._vision_dist_smoothed
                    # Setpoint bajo en la rama visión: el dron sigue acercándose en
                    # vez de frenar en el setpoint real (la visión infravalora); el
                    # ToF, al activarse, hace la parada fina en INTERCEPT_DISTANCE_CM.
                    error_pitch = VISION_APPROACH_SETPOINT_CM - dist_for_pid
                    if self._pitch_source_last != 'tof_vision':
                        self.pitch_pid.error_last = error_pitch
                    fb = self.pitch_pid.compute(error_pitch, dt)
                    if abs(error_pitch) < FOLLOW_PITCH_DEADBAND_CM:
                        fb = 0.0
                    fb = self._shape_pitch_fb(fb, dist_for_pid, VISION_APPROACH_SETPOINT_CM)
                    self.pitch_bbox_pid.reset_integral()
                    self._follow_status = 'tof_vision'
                    self._tof_display = dist_for_pid

                elif self._closeness_ema_initialized:
                    pitch_source = 'bbox'
                    # closeness_setpoint: queremos bbox_height_ratio = 0.45
                    # (equivalente a BBOX_HEIGHT_RATIO_SETPOINT del proyecto referencia)
                    CLOSENESS_SETPOINT = 0.45
                    # closeness CRECE con la proximidad (es ~1/distancia), al revés que
                    # el ToF. error = closeness - setpoint para que LEJOS (closeness baja)
                    # dé error<0 y, con kp<0, fb>0 = avanzar — igual signo que la rama ToF
                    # (error=setpoint-dist, kp<0). Antes era setpoint-closeness, que con
                    # kp=-70 empujaba HACIA ATRÁS cuando la persona estaba lejos (bug: el
                    # fallback bbox alejaba al dron en vez de acercarlo).
                    error_pitch = self._closeness_smoothed - CLOSENESS_SETPOINT
                    # Sembrar error_last al entrar en bbox → evita spike D-term
                    if self._pitch_source_last != 'bbox':
                        self.pitch_bbox_pid.error_last = error_pitch
                    fb = self.pitch_bbox_pid.compute(error_pitch, dt)
                    # Banda muerta (en ratio): análogo al ToF, evita oscilar.
                    if abs(error_pitch) < FOLLOW_PITCH_DEADBAND_RATIO:
                        fb = 0.0
                    self.pitch_pid.reset_integral()
                    self._follow_status = 'following'
                    self._tof_display = -1.0

                else:
                    pitch_source = 'none'
                    fb = 0.0
                    self.pitch_pid.reset_integral()
                    self.pitch_bbox_pid.reset_integral()

                # ── Wall stop ────────────────────────────────────────
                if valid_front_tof and current_tof_cm <= FRONT_TOF_WALL_STOP_CM and fb > 0:
                    fb = 0
                    self.pitch_pid.reset_integral()
                    self.pitch_bbox_pid.reset_integral()

                # ── Guardia diagonal (freeze fb) ─────────────────────
                if time.time() < self._front_tof_freeze_until and fb > 0:
                    fb = 0
                    self.pitch_pid.reset_integral()
                    self.pitch_bbox_pid.reset_integral()

                lr = 0   # Follow no usa roll lateral

            # ────────────────────────────────────────────────────────
            # HOVER (grace period)
            # ────────────────────────────────────────────────────────
            elif (not orbit_mode and
                  self._last_target_seen_time > 0 and
                  (now - self._last_target_seen_time) < TARGET_LOST_GRACE_S):
                self._follow_status = 'grace'
                self._tof_display = -1.0
                ud  = 0.0
                fb  = 0.0
                # Yaw de recuperación: girar hacia el lado donde estaba el objetivo
                yaw = self._last_target_side * 15
                lr  = 0
                self.yaw_pid.reset_integral()
                self.altitude_pid.reset_integral()
                self.pitch_pid.reset_integral()
                self.pitch_bbox_pid.reset_integral()
                # Reset EMA para próxima adquisición
                self._target_ema_initialized     = False
                self._closeness_ema_initialized  = False

            # ────────────────────────────────────────────────────────
            # SEARCHING (spin 360°)
            # ────────────────────────────────────────────────────────
            elif not orbit_mode:
                self._follow_status = 'searching'
                self._tof_display   = -1.0
                self._target_ema_initialized    = False
                self._closeness_ema_initialized = False
                # Re-ID: objetivo definitivamente perdido → liberar el ancla para
                # poder readquirir a CUALQUIER persona durante el spin de búsqueda.
                self._target_id = None
                self._reset_gesture_state()
                self.altitude_pid.reset_integral()
                self.pitch_pid.reset_integral()
                self.pitch_bbox_pid.reset_integral()
                self.yaw_pid.reset_integral()
                fb  = 0
                lr  = 0
                ud  = 0

                if self._search_state == 'none':
                    self._search_state = 'spin'
                    self._search_spin_start_t = time.time()

                if self._search_state == 'spin':
                    spin_sign = self._last_target_side if self._last_target_side != 0 else 1
                    yaw = spin_sign * SEARCH_SPIN_VELOCITY_DEG_S
                    # Parada por tiempo, no por acumulación de dt: el dt del video
                    # loop varía ~10x con/sin YOLO (10-300ms), haciendo el corte a
                    # 360° poco fiable (giro real de 200-450°).
                    elapsed_spin = time.time() - self._search_spin_start_t
                    if elapsed_spin * SEARCH_SPIN_VELOCITY_DEG_S >= 360.0:
                        # 360° completados → parar, esperar nueva detección
                        yaw = 0
                        self._search_state = 'none'
                        self._search_spin_start_t = 0.0

            # ════════════════════════════════════════════════════════════════════
            # ORBIT FSM — sobreescribe lr/fb/ud/yaw calculados por el Follow FSM
            # Solo actúa si _orbit_mode == True
            # ════════════════════════════════════════════════════════════════════
           
            if orbit_mode:
                # Resetear los RC calculados por el Follow FSM
                lr = 0; fb = 0; ud = 0; yaw = 0

                # ── Tamaño aparente (bbox closeness) por frame ───────────────
                # Réplica local del cálculo del Follow (:905-913). En Orbit el
                # FollowController es nuevo y la rama Follow no se ejecuta, así que
                # SIN esto el closeness nunca se inicializa y la órbita se queda sin
                # señal de distancia robusta al giro (solo ToF, que falla al orbitar).
                # No se toca la rama Follow: se duplica aquí a propósito.
                if tracking_target_raw and best is not None:
                    x1, y1, x2, y2, *_ = best
                    raw_closeness = (y2 - y1) / float(actual_h)
                    if not self._closeness_ema_initialized:
                        self._closeness_smoothed = raw_closeness
                        self._closeness_ema_initialized = True
                    else:
                        self._closeness_smoothed = (TARGET_EMA_ALPHA * raw_closeness +
                                                    (1 - TARGET_EMA_ALPHA) * self._closeness_smoothed)

                # ── Altitud: igual que Follow — mantener hombros al 25% ──────
                # Solo aplicar altitud si hay target visible
                if tracking_target and self._target_ema_initialized:
                    error_altitude = self._target_smoothed_y_px - target_setpoint_y_px
                    ud = self.altitude_pid.compute(error_altitude, dt)
                else:
                    ud = 0
                    self.altitude_pid.reset_integral()

                # ── Fuente de distancia (igual que Follow: ToF > bbox) ────────
                # Reutiliza la lógica ya ejecutada arriba: valid_front_tof,
                # _last_valid_front_tof_cm, _tof_invalid_count, _closeness_smoothed
                if (self._last_valid_front_tof_cm > 0 and
                        self._tof_invalid_count < FRONT_TOF_INVALID_HYSTERESIS_FRAMES):
                    orbit_dist_cm = (current_tof_cm if valid_front_tof
                                    else self._last_valid_front_tof_cm)
                    orbit_dist_source = 'tof'
                    self._orbit_tof_display = orbit_dist_cm
                elif self._closeness_ema_initialized:
                    # Convertir closeness_ratio a cm estimados (lineal calibrado)
                    # closeness=0.55 → ~100cm, closeness=0.35 → ~157cm
                    # Fórmula: dist_cm = ORBIT_RADIUS_CM * (ORBIT_CLOSENESS_SETPOINT / closeness)
                    if self._closeness_smoothed > 0.01:
                        orbit_dist_cm = self._orbit_radius_cm * (
                            ORBIT_CLOSENESS_SETPOINT / self._closeness_smoothed)
                    else:
                        orbit_dist_cm = self._orbit_radius_cm * 2.0
                    orbit_dist_source = 'bbox'
                    self._orbit_tof_display = -1.0
                else:
                    orbit_dist_cm = -1.0
                    orbit_dist_source = 'none'
                    self._orbit_tof_display = -1.0

                # ── FSM de Orbit ──────────────────────────────────────────────
                # Estado: 'search' | 'approach' | 'align' | 'orbit' | 'lost' | 'hover_safe'

                if self._orbit_state == 'search':
                    # ── SEARCH: esperar a tener target y latchear el radio ────
                    self._orbit_status = 'searching'
                    self._orbit_ramp = 0.0
                    self.tangential_pid.reset_integral()
                    self.tangential_pid.error_last = 0.0

                    if tracking_target and not self._orbit_radius_latched:
                        # Radio automático: fijarlo a la distancia ACTUAL a la persona.
                        # Preferimos ToF (medida radial real). Si no llega un ToF válido
                        # a tiempo, fallback al radio por defecto (persona fuera de rango).
                        if (self._last_valid_front_tof_cm > 0 and
                                self._tof_invalid_count < FRONT_TOF_INVALID_HYSTERESIS_FRAMES):
                            self._orbit_radius_cm = max(
                                ORBIT_RADIUS_MIN_CM,
                                min(ORBIT_RADIUS_MAX_CM, self._last_valid_front_tof_cm))
                            self._orbit_radius_latched = True
                            # Ir a ALIGN (no a ORBIT): centra el yaw antes de girar; como
                            # radio == distancia actual, la corrección radial es ≈0 → solo
                            # centra y orbita desde donde está.
                            self._orbit_state = 'align'
                            self._orbit_status = 'aligning'
                            self._orbit_align_start_time = now
                            self._orbit_align_stable_count = 0
                            self.pitch_pid.reset_integral()
                            self.yaw_pid.reset_integral()
                            print(f'[ORBIT] Radio fijado a {self._orbit_radius_cm:.0f}cm '
                                  f'(ToF)')
                        elif self._closeness_ema_initialized and self._closeness_smoothed > 0.01:
                            # Sin ToF fiable (RMTT lo rechaza), pero ya hay tamaño aparente:
                            # estimar el radio en cm desde el closeness y pasar a ALIGN sin
                            # esperar el timeout. La distancia real se mantendrá luego por
                            # tamaño aparente (latch al entrar en 'orbit'), así que este cm
                            # solo fija los umbrales de approach/align.
                            self._orbit_radius_cm = max(
                                ORBIT_RADIUS_MIN_CM,
                                min(ORBIT_RADIUS_MAX_CM,
                                    ORBIT_RADIUS_CM * (ORBIT_CLOSENESS_SETPOINT
                                                       / self._closeness_smoothed)))
                            self._orbit_radius_latched = True
                            self._orbit_state = 'align'
                            self._orbit_status = 'aligning'
                            self._orbit_align_start_time = now
                            self._orbit_align_stable_count = 0
                            self.pitch_pid.reset_integral()
                            self.yaw_pid.reset_integral()
                            print(f'[ORBIT] Radio ~{self._orbit_radius_cm:.0f}cm '
                                  f'(tamaño aparente, sin ToF)')
                        elif now - self._orbit_search_start_time > ORBIT_RADIUS_LATCH_TIMEOUT_S:
                            self._orbit_radius_cm = ORBIT_RADIUS_CM
                            self._orbit_radius_latched = True
                            self._orbit_state = 'approach'
                            self._orbit_status = 'approach'
                            self.pitch_pid.reset_integral()
                            self.pitch_bbox_pid.reset_integral()
                            print(f'[ORBIT] Sin ToF ni tamaño aparente — radio por defecto '
                                  f'{ORBIT_RADIUS_CM:.0f}cm')
                        else:
                            # Esperando señal de distancia: centrar el yaw sin avanzar.
                            error_yaw = self._target_smoothed_x_px - frame_center_x
                            yaw = self.yaw_pid.compute(error_yaw, dt)
                            fb = 0; lr = 0; ud = 0
                    elif tracking_target and self._orbit_radius_latched:
                        # Radio ya fijado (re-acquire tras 'lost'): volver por APPROACH.
                        self._orbit_state = 'approach'
                        self._orbit_status = 'approach'
                        self.pitch_pid.reset_integral()
                        self.pitch_bbox_pid.reset_integral()
                    else:
                        # Sin target: spin suave buscando (igual que Follow SEARCH)
                        spin_sign = self._last_target_side if self._last_target_side != 0 else 1
                        yaw = spin_sign * SEARCH_SPIN_VELOCITY_DEG_S
                        fb = 0; lr = 0; ud = 0

                elif self._orbit_state == 'approach':
                    # ── APPROACH: avanzar hasta ORBIT_ALIGN_ENTER_CM ─────────
                    self._orbit_status = 'approach'
                    self._orbit_ramp = 0.0

                    if not tracking_target:
                        self._orbit_lost_count += 1
                        if self._orbit_lost_count >= ORBIT_LOST_FRAMES:
                            self._orbit_lost_start_time = now
                            self._orbit_state = 'lost'
                    else:
                        self._orbit_lost_count = 0

                    if tracking_target:
                        # Yaw: centrar la persona
                        error_yaw = self._target_smoothed_x_px - frame_center_x
                        yaw = self.yaw_pid.compute(error_yaw, dt)

                        if orbit_dist_source != 'none':
                            error_pitch = self._orbit_radius_cm - orbit_dist_cm
                            if self._pitch_source_last != 'tof_orbit':
                                self.pitch_pid.error_last = error_pitch
                            fb = self.pitch_pid.compute(error_pitch, dt)

                            # Transición a ALIGN cuando estamos suficientemente cerca.
                            # Relativo al radio (no absoluto) para soportar radio dinámico.
                            if orbit_dist_cm <= self._orbit_radius_cm + ORBIT_ALIGN_ENTER_MARGIN_CM:
                                self._orbit_state = 'align'
                                self._orbit_align_start_time = now
                                self._orbit_align_stable_count = 0
                                self.pitch_pid.reset_integral()
                                self.yaw_pid.reset_integral()
                        else:
                            fb = 0

                        lr = 0
                        self._pitch_source_last = 'tof_orbit'

                elif self._orbit_state == 'align':
                    # ── ALIGN: ajuste fino yaw + distancia antes de orbitar ──
                    self._orbit_status = 'aligning'
                    self._orbit_ramp = 0.0

                    if not tracking_target:
                        self._orbit_lost_count += 1
                        if self._orbit_lost_count >= ORBIT_LOST_FRAMES:
                            self._orbit_lost_start_time = now
                            self._orbit_state = 'lost'
                    else:
                        self._orbit_lost_count = 0

                    # Timeout de alineación: si tardamos demasiado, reintentar APPROACH
                    if now - self._orbit_align_start_time > ORBIT_ALIGN_TIMEOUT_S:
                        self._orbit_state = 'approach'
                        self.pitch_pid.reset_integral()
                        self.yaw_pid.reset_integral()

                    elif tracking_target and orbit_dist_source != 'none':
                        error_yaw = self._target_smoothed_x_px - frame_center_x
                        error_dist = self._orbit_radius_cm - orbit_dist_cm

                        yaw = self.yaw_pid.compute(error_yaw, dt)

                        # Corregir distancia con la misma tolerancia que define
                        # "estable" (ORBIT_STABLE_TOF_MARGIN_CM). Usar
                        # ORBIT_ALIGN_EXIT_CM - radius (=35cm) dejaba una zona muerta
                        # [8,35]cm sin corrección ni estabilidad → ALIGN perpetuo.
                        if abs(orbit_dist_cm - self._orbit_radius_cm) > ORBIT_STABLE_TOF_MARGIN_CM:
                            fb = self.pitch_pid.compute(error_dist, dt)
                        else:
                            fb = 0
                            self.pitch_pid.reset_integral()

                        lr = 0

                        # Condición de estabilidad para entrar en ORBIT
                        yaw_stable = abs(error_yaw) < ORBIT_ALIGN_PX_THRESH
                        dist_stable = abs(error_dist) < ORBIT_STABLE_TOF_MARGIN_CM
                        if yaw_stable and dist_stable:
                            self._orbit_align_stable_count += 1
                            if self._orbit_align_stable_count >= ORBIT_ALIGN_STABLE_FRAMES:
                                # ¡Condiciones cumplidas! → ORBIT
                                # Fijar el radio a la distancia REAL en este instante: el
                                # Orbit mantendrá EXACTAMENTE la distancia a la que empieza
                                # a orbitar (lo que pide el usuario), sin acercarse ni
                                # alejarse a otro valor. Preferir ToF (medida directa).
                                if orbit_dist_source != 'none':
                                    self._orbit_radius_cm = max(
                                        ORBIT_RADIUS_MIN_CM,
                                        min(ORBIT_RADIUS_MAX_CM, orbit_dist_cm))
                                self._orbit_state = 'orbit'
                                self._orbit_ramp = 0.0
                                self._orbit_lr_prev = 0.0
                                self._orbit_fb_prev = 0.0
                                self._orbit_dist_initialized = False
                                self.tangential_pid.reset_integral()
                                self.tangential_pid.error_last = 0.0
                                self.yaw_pid.reset_integral()
                                self.pitch_pid.reset_integral()
                                print(f'[ORBIT] Orbitando — radio {self._orbit_radius_cm:.0f}cm '
                                      f'(distancia al empezar)')
                        else:
                            self._orbit_align_stable_count = 0

                        self._pitch_source_last = 'tof_orbit'

                elif self._orbit_state == 'orbit':
                    # ── ORBIT: movimiento tangencial + corrección radial ──────
                    self._orbit_status = 'orbiting'

                    if not tracking_target:
                        self._orbit_lost_count += 1
                        if self._orbit_lost_count >= ORBIT_LOST_FRAMES:
                            self._orbit_lost_start_time = now
                            self._orbit_state = 'lost'
                            self._orbit_ramp = 0.0
                    else:
                        self._orbit_lost_count = 0

                    if tracking_target:
                        # Rampa de velocidad tangencial (suavizado de entrada)
                        self._orbit_ramp = min(1.0, self._orbit_ramp + ORBIT_RAMP_STEP)

                        # Yaw: feedforward anticipativo + PID correctivo.
                        # El FF debe ser OPUESTO al lr: si el dron se desliza a la
                        # derecha (lr>0) la persona se va a la izquierda del encuadre, y
                        # hay que yaw a la izquierda para recentrar. Antes el FF usaba el
                        # mismo signo que el lr → peleaba contra el yaw PID y costaba
                        # quedarse mirando a la persona. De ahí el -self._orbit_sign.
                        # Escala por radio: ω = v_tangencial/R, así que a radio menor
                        # (p.ej. 60) hace falta más yaw por unidad de lr; el factor
                        # ORBIT_RADIUS_CM/radio refuerza el FF en círculos cerrados.
                        error_yaw = self._target_smoothed_x_px - frame_center_x
                        yaw_ff = (-self._orbit_sign * ORBIT_YAW_FF_GAIN
                                  * (ORBIT_RADIUS_CM / max(1.0, self._orbit_radius_cm))
                                  * self._orbit_tangential_ff * self._orbit_ramp)
                        yaw = int(round(yaw_ff + self.yaw_pid.compute(error_yaw, dt)))
                        yaw = max(-YAW_MAX_VELOCITY, min(YAW_MAX_VELOCITY, yaw))

                        # LR tangencial: feedforward * rampa + corrección PID centrado
                        # El PID tangencial corrige el error de centrado horizontal
                        # para mantener la persona en el centro mientras orbita
                        tangential_correction = self.tangential_pid.compute(
                            error_yaw, dt)
                        lr = int(round(
                            self._orbit_sign * self._orbit_tangential_ff * self._orbit_ramp
                            + tangential_correction
                        ))
                        lr = max(-ORBIT_LR_MAX_VELOCITY, min(ORBIT_LR_MAX_VELOCITY, lr))

                        # FB radial: mantener el radio con el ToF (señal métrica fiable).
                        # error_dist = radio − distancia. Demasiado cerca (dist<radio) →
                        # error>0 → con kp<0, fb<0 = retroceder (alejarse). Demasiado lejos →
                        # error<0 → fb>0 = avanzar. Esto es lo que faltaba con el closeness:
                        # el ToF SÍ detecta "demasiado cerca" y empuja hacia atrás.
                        if orbit_dist_source != 'none':
                            # Suavizar la distancia (orbit-only) antes del lazo: filtra el
                            # ruido del ToF que hacía oscilar el radio y cruzar el wall-stop.
                            if not self._orbit_dist_initialized:
                                self._orbit_dist_smoothed = orbit_dist_cm
                                self._orbit_dist_initialized = True
                            else:
                                self._orbit_dist_smoothed = (
                                    ORBIT_DIST_EMA_ALPHA * orbit_dist_cm +
                                    (1 - ORBIT_DIST_EMA_ALPHA) * self._orbit_dist_smoothed)
                            dist_for_radial = self._orbit_dist_smoothed
                            error_dist = self._orbit_radius_cm - dist_for_radial

                            # Deriva grande hacia afuera → volver a 'align' para recentrar
                            # y recuperar el radio antes de seguir orbitando.
                            if dist_for_radial > self._orbit_radius_cm + ORBIT_MAX_DRIFT_CM:
                                self._orbit_state = 'align'
                                self._orbit_ramp = 0.0
                                self._orbit_align_start_time = now
                                self._orbit_align_stable_count = 0
                                # Resetear histéresis de pérdida: si no, un frame sin
                                # target en align podría disparar 'lost' saltándose la gracia.
                                self._orbit_lost_count = 0
                                self.pitch_pid.reset_integral()
                                self.yaw_pid.reset_integral()

                            if self._pitch_source_last != 'tof_orbit':
                                self.pitch_pid.error_last = error_dist
                            fb = self.pitch_pid.compute(error_dist, dt)
                            # Banda muerta: cerca del radio, no temblar.
                            if abs(error_dist) < ORBIT_RADIAL_DEADBAND_CM:
                                fb = 0.0

                            # Feedforward centrípeto: pequeño sesgo inward para compensar la
                            # fuga radial del strafe+yaw sin esperar al PID. Reducido (0.10)
                            # para que NO sesgue hacia dentro: el ToF cierra el lazo y manda.
                            fb += (ORBIT_RADIAL_FF_GAIN
                                   * self._orbit_tangential_ff * self._orbit_ramp)
                            fb = max(-FB_MAX_VELOCITY, min(FB_MAX_VELOCITY, fb))
                        else:
                            fb = 0
                            self.pitch_pid.reset_integral()

                        # Wall stop específico de Orbit (ToF = freno anti-choque).
                        # SOLO limita el avance hacia delante (fb): el sensor frontal apunta
                        # a la persona (centro de la órbita), no a la dirección de avance, así
                        # que el strafe tangencial (lateral) es seguro estando cerca. NO se
                        # anula lr: hacerlo paraba la vuelta en seco cuando la oscilación
                        # radial cruzaba el umbral. El lazo radial saca al dron al radio.
                        if valid_front_tof and current_tof_cm <= ORBIT_WALL_STOP_CM:
                            fb = min(0, fb)  # Solo permite alejarse, no acercarse
                            self.pitch_pid.reset_integral()

                        # ── Slew-rate de lr y fb (solo Orbit) ─────────────────
                        # Suavizan escalones entre frames (hueco de detección, parpadeo del
                        # haz del ToF) para que la vuelta no dé tirones.
                        delta_lr = lr - self._orbit_lr_prev
                        if delta_lr > ORBIT_LR_SLEW_RATE_PER_FRAME:
                            lr = self._orbit_lr_prev + ORBIT_LR_SLEW_RATE_PER_FRAME
                        elif delta_lr < -ORBIT_LR_SLEW_RATE_PER_FRAME:
                            lr = self._orbit_lr_prev - ORBIT_LR_SLEW_RATE_PER_FRAME
                        lr = int(round(lr))
                        self._orbit_lr_prev = lr

                        delta_fb = fb - self._orbit_fb_prev
                        if delta_fb > ORBIT_FB_SLEW_RATE_PER_FRAME:
                            fb = self._orbit_fb_prev + ORBIT_FB_SLEW_RATE_PER_FRAME
                        elif delta_fb < -ORBIT_FB_SLEW_RATE_PER_FRAME:
                            fb = self._orbit_fb_prev - ORBIT_FB_SLEW_RATE_PER_FRAME
                        self._orbit_fb_prev = fb

                        self._pitch_source_last = 'tof_orbit'

                elif self._orbit_state == 'lost':
                    # ── LOST: grace period antes de volver a SEARCH ──────────
                    self._orbit_status = 'lost'
                    self._orbit_ramp = 0.0
                    lr = 0; fb = 0; yaw = 0

                    if tracking_target:
                        # Reacquired → volver a APPROACH
                        self._orbit_lost_count = 0
                        self._orbit_state = 'approach'
                        self.pitch_pid.reset_integral()
                        self.yaw_pid.reset_integral()
                    elif now - self._orbit_lost_start_time > ORBIT_LOST_GRACE_S:
                        # Grace expirado → volver a SEARCH
                        self._orbit_state = 'search'

                elif self._orbit_state == 'hover_safe':
                    # ── HOVER_SAFE: parada de emergencia dentro de Orbit ──────
                    self._orbit_status = 'hover_safe'
                    lr = 0; fb = 0; yaw = 0; ud = 0
                    self._orbit_ramp = 0.0
                    self.altitude_pid.reset_integral()

                # ── Freeze diagonal: NO se aplica en Orbit ────────────────────
                # (Este bloque está dentro de `if orbit_mode:`.) En Follow, el freeze
                # pone fb=0 cuando el ToF salta válido→-1.0; en Orbit eso bloquearía el
                # empuje hacia adelante justo al perder a la persona, impidiendo la
                # recuperación. La protección anti-choque en Orbit ya la da su propio
                # wall-stop (ORBIT_WALL_STOP_CM, arriba), así que aquí se omite a
                # propósito. El freeze de Follow sigue vigente en su propia rama.

                # ── Límite de altitud también aplica en Orbit ─────────────────
                # (height_cm viene del tello state — ya disponible en el scope)
                # NOTA: height_cm debe existir en scope; si no está disponible
                # en tu _video_loop actual, omitir estas dos guards por ahora
                # y añadirlas cuando se integre la lectura de altitud.

            # ── Latch pitch source para siguiente frame ───────────────
            # En orbit, las ramas internas ya actualizan _pitch_source_last
            # a 'tof_orbit'; no sobreescribir con el valor del Follow FSM.
            if not orbit_mode:
                self._pitch_source_last = pitch_source

            # ── Slew-rate de fb (solo Follow) ─────────────────────────
            # Suaviza saltos de fb tras un hueco de stream: una detección que
            # reaparece de golpe no debe traducirse en un acelerón hacia la
            # persona. Orbit tiene su propia dinámica de aproximación y se excluye.
            if not orbit_mode:
                delta_fb = fb - self._fb_prev
                if delta_fb > FB_SLEW_RATE_PER_FRAME:
                    fb = self._fb_prev + FB_SLEW_RATE_PER_FRAME
                elif delta_fb < -FB_SLEW_RATE_PER_FRAME:
                    fb = self._fb_prev - FB_SLEW_RATE_PER_FRAME
            self._fb_prev = fb

            # ── Escribir RC ──────────────────────────────────────────
            with self._rc_lock:
                self._rc = [int(round(lr)), int(round(fb)),
                            int(round(ud)), int(round(yaw))]

            # ── Frame debug ──────────────────────────────────────────
            if best is not None and tracking_target_raw:
                x1, y1, x2, y2, *_ = best
                cv2.rectangle(frame_bgr, (x1, y1), (x2, y2), (250, 150, 0), 2)
                if tracked_shoulder_cy is not None:
                    cx_vis = int((x1 + x2) / 2)
                    cv2.circle(frame_bgr, (cx_vis, int(tracked_shoulder_cy)), 6, (0, 255, 255), -1)
            cv2.circle(frame_bgr, (frame_center_x, target_setpoint_y_px), 8, (0, 255, 0), 2)
            if self._target_ema_initialized:
                cv2.circle(frame_bgr, (int(self._target_smoothed_x_px),
                                    int(self._target_smoothed_y_px)), 5, (255, 0, 255), -1)

            # HUD de texto (Y/T/FB, miss/tof_inv, id/gest/fps, [YOLO]/[EMA])
            # eliminado a petición del usuario: el stream de follow/orbit va limpio
            # de números y palabras; se mantienen solo el bbox y los círculos.

            with self._frame_lock:
                out = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)
                self._debug_frame = cv2.resize(out, (640, 480), interpolation=cv2.INTER_LINEAR)
                self._debug_frame_ts = time.time()

            # ── FPS log (B3): cada ~2s, para validar el rendimiento en GPU ──
            _fps_frames += 1
            _dt_fps = time.time() - _fps_t0
            if _dt_fps >= 2.0:
                _fps_last = _fps_frames / _dt_fps
                print(f'[FOLLOW] video loop ~{_fps_last:.1f} FPS '
                      f'(stride={YOLO_FRAME_STRIDE}, imgsz={POSE_IMGSZ})')
                _fps_t0 = time.time()
                _fps_frames = 0

            # Pacing: tope a VIDEO_LOOP_TARGET_FPS. Con la GPU potente subimos de
            # 30 a ~60 FPS (más detecciones/seg ⇒ tracking y control de distancia
            # más finos). dt es dt-aware en los PID, así que no hay wind-up extra;
            # si el GPU no llega, el loop corre a su ritmo natural (sleep≈0).
            time.sleep(max(0.0, (1.0 / VIDEO_LOOP_TARGET_FPS) - (time.time() - _now_t)))

    # ------------------------------------------------------------------ API pública
    def get_debug_frame(self, max_age_s: float = None):
        """Devuelve el último frame debug. Si se pasa max_age_s y el frame es
        más antiguo que ese umbral (el follow loop se ha retrasado/atascado),
        devuelve None para que el caller muestre vídeo en vivo en su lugar."""
        with self._frame_lock:
            if max_age_s is not None and (time.time() - self._debug_frame_ts) > max_age_s:
                return None
            return self._debug_frame

    def stop(self):
        self._active = False
        # Esperar a que los hilos terminen de verdad (evita hilos zombi que
        # impidan reiniciar Follow/Orbit limpiamente).
        for name in ('_vid_thread', '_rc_thread', '_tof_thread'):
            th = getattr(self, name, None)
            if th is not None and th.is_alive():
                th.join(timeout=1.5)
                if th.is_alive():
                    print(f'[FOLLOW] {name} no termino en el timeout de stop()')
        try:
            self._tello.rc(0, 0, 0, 0)
        except Exception:
            pass

    def reset_pids(self):
        self.yaw_pid.reset_integral()
        self.altitude_pid.reset_integral()
        self.pitch_pid.reset_integral()
        self.pitch_bbox_pid.reset_integral()
        self._pitch_source_last = 'none'
        with self._tof_lock:
            self.front_tof_cm = -1.0
        self._last_valid_front_tof_cm = -1.0
        self._tof_invalid_count       = 0
        self._tof_cm_prev             = -1.0
        self._front_tof_freeze_until  = 0.0
        self._vision_dist_cm             = -1.0
        self._vision_dist_smoothed       = 0.0
        self._vision_dist_initialized    = False
        self._target_ema_initialized     = False
        self._closeness_ema_initialized  = False
        self._tracking_miss_count        = 0
        self._search_state               = 'none'
        self._search_spin_angle_deg      = 0.0
        self._follow_status  = 'waiting'
        self._tof_display    = -1.0
        # Orbit state reset
        self.tangential_pid.reset_integral()
        self.tangential_pid.error_last = 0.0
        self._orbit_state = 'search'
        self._orbit_ramp = 0.0
        self._orbit_lost_count = 0
        self._orbit_align_start_time = 0.0
        self._orbit_align_stable_count = 0
        self._orbit_lost_start_time = 0.0
        self._orbit_status = 'waiting'
        self._orbit_tof_display = -1.0
        self._orbit_sign = 1
        self._orbit_lr_prev = 0.0
        self._orbit_fb_prev = 0.0
        self._orbit_dist_smoothed = 0.0
        self._orbit_dist_initialized = False

        with self._rc_lock:
            self._rc = [0, 0, 0, 0]
        with self._frame_lock:
            self._debug_frame = None

    def activate_orbit(self, radius_cm: float | None = None,
                    clockwise: bool = True) -> None:
        """
        Activa el modo Orbit sobre el FollowController activo.
        Puede llamarse con el controller ya en vuelo (tras Follow activo)
        o en frío (el controller arranca directamente en FSM de Orbit).

        radius_cm=None (por defecto) → modo AUTO: el radio se latchea a la distancia
        ToF actual a la persona en el estado 'search' (orbita desde donde está). Si se
        pasa un número, se usa ese radio fijo (compat con el slider antiguo).
        """
        # Preparar TODO el estado de Orbit ANTES de activar el flag. El
        # _video_loop_inner snapshotea _orbit_mode una vez por frame; escribirlo
        # el último (GIL → escritura atómica) garantiza que cuando el loop lo vea
        # True, radio/sign/state/ramp/PIDs ya están coherentes. Antes, poner
        # _orbit_mode=True primero permitía ejecutar el Orbit FSM con PIDs sin
        # resetear y radio/dir antiguos → spike de lr en la dirección anterior.
        if radius_cm is None:
            # Auto: el radio se fija en 'search' con la primera lectura ToF válida.
            self._orbit_radius_cm = ORBIT_RADIUS_CM   # fallback hasta el latch
            self._orbit_radius_latched = False
        else:
            self._orbit_radius_cm = radius_cm
            self._orbit_radius_latched = True
        self._orbit_search_start_time = time.time()
        # Signo del lr tangencial. CW (etiqueta) debe mover el dron a su IZQUIERDA
        # (lr<0) para rodear a la persona en sentido horario; con +1 se desplazaba a
        # la derecha y orbitaba CCW (botones cruzados, reportado en vuelo). El yaw_ff
        # usa -self._orbit_sign para acompañar el rumbo de forma coherente.
        self._orbit_sign = -1 if clockwise else 1
        self._orbit_ramp = 0.0
        self._orbit_lr_prev = 0.0
        self._orbit_fb_prev = 0.0
        self._orbit_dist_initialized = False
        self._orbit_state = 'search'
        self._orbit_lost_count = 0
        self._orbit_status = 'activating'
        # Resetear PIDs de control para evitar wind-up heredado del Follow
        self.yaw_pid.reset_integral()
        self.altitude_pid.reset_integral()
        self.pitch_pid.reset_integral()
        self.pitch_bbox_pid.reset_integral()
        self.tangential_pid.reset_integral()
        self.tangential_pid.error_last = 0.0
        # Activar el flag como ÚLTIMO paso (ver comentario arriba).
        self._orbit_mode = True
        radio_str = f'{radius_cm}cm' if radius_cm is not None else 'auto (distancia actual)'
        print(f'[ORBIT] Activado — radio={radio_str}, '
            f'dir={"CW" if clockwise else "CCW"}')

    def deactivate_orbit(self) -> None:
        """Desactiva el modo Orbit y vuelve al Follow normal."""
        # Neutralizar RC y resetear estado ANTES de bajar el flag. _orbit_mode se
        # escribe el último para que el snapshot del _video_loop sea coherente:
        # mientras es True ejecuta Orbit; al verlo False, retoma Follow con estado
        # ya limpio.
        with self._rc_lock:
            self._rc = [0, 0, 0, 0]
        self._orbit_state = 'search'
        self._orbit_ramp = 0.0
        self._orbit_status = 'off'
        self._orbit_tof_display = -1.0
        self._orbit_mode = False
        print('[ORBIT] Desactivado — volviendo a Follow')
