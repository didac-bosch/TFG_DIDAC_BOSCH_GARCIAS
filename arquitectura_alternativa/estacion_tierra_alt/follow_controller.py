# ============================================================
# follow_controller.py — modos autonomos del Tello: FOLLOW y ORBIT.
#
# La estacion de tierra (estacion_tierra.py) crea un FollowController cuando el
# usuario activa "seguir persona" u "orbitar". A partir de ahi el dron se controla
# solo, sin joystick, usando lo que ve la camara:
#   1. Detecta personas con YOLO-pose y se ancla a UNA (tracker con re-ID) para no
#      saltar a otra si aparecen varias.
#   2. Con PIDs decide como moverse: gira (yaw) para centrarla, sube/baja para
#      encuadrarla y avanza/retrocede para mantener la distancia.
#   3. Mide la distancia con el sensor ToF frontal y, de respaldo, estimandola por
#      el ancho de hombros en la imagen.
# Follow = mantenerse a una distancia fija de la persona. Orbit = girar a su
# alrededor a radio constante. Todo corre en hilos daemon (video, RC y ToF).
#
# La mayoria de constantes de abajo son ganancias/umbrales que se afinaron probando
# en vuelo real; el comentario de cada una dice para que sirve.
# ============================================================

import threading
import time
import re
import cv2
import numpy as np

# ============================================================
# PID CONTROLLER
# ============================================================

# PID clasico (proporcional-integral-derivativo): a partir de un error (p.ej.
# "la persona esta 80 px a la derecha del centro") calcula la velocidad a aplicar.
class PIDController:
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

    # Calcula la salida del PID para el error actual y el tiempo transcurrido (dt)
    def compute(self, error: float, dt: float) -> float:
        if dt <= 0:
            return 0.0
        self.error = error
        self.integral_error += error * dt
        # Anti-windup: acota el termino integral al rango de salida para que no se
        # dispare y sature cuando el error persiste mucho tiempo.
        if self.ki != 0:
            i_max = abs(self.output_max / self.ki)
            self.integral_error = max(-i_max, min(i_max, self.integral_error))
        self.derivative_error = (error - self.error_last) / dt
        self.error_last = error
        output = self.kp * self.error + self.ki * self.integral_error + self.kd * self.derivative_error
        output = max(self.output_min, min(self.output_max, output))
        self.velocity_command = output
        return output

    # Pone a cero el acumulador integral (al cambiar de objetivo o de modo)
    def reset_integral(self) -> None:
        self.integral_error = 0.0


# ============================================================
# FOLLOW CONTROLLER  
# ============================================================

# --- Ganancias de los PID (kp, ki, kd), afinadas probando en vuelo ---
GAINS_YAW_PID         = (0.2,  0.002,  0.1)        # giro: centrar a la persona en horizontal
GAINS_ALTITUDE_PID    = (-0.08,  -0.002,  -0.020)  # subir/bajar: mantenerla bien encuadrada
# Avance/retroceso guiado por el ToF. El kd es alto para frenar a tiempo y que el
# dron no se pase de largo al acercarse (el sensor llega con algo de retraso).
GAINS_FORWARD_BACK_TOF_PID  = (-0.45,  -0.03,  -0.85)
GAINS_FORWARD_BACK_BBOX_PID = (-70.0, -8.0,  -150.0)  # lo mismo pero midiendo por el tamano de la caja

# --- Topes de velocidad (unidades RC del Tello) ---
# Lejos de la persona el PID de avance satura, asi que FB_MAX es en la practica la
# velocidad de acercamiento. Si el dron oscila al llegar, bajar FB_MAX_VELOCITY.
YAW_MAX_VELOCITY      = 55
UD_MAX_VELOCITY       = 35
FB_MAX_VELOCITY       = 50

# Banda muerta de distancia (cm): si el dron esta casi a la distancia deseada, no
# avanza ni retrocede. Evita el vaiven adelante/atras cuando oscila cerca del objetivo.
FOLLOW_PITCH_DEADBAND_CM = 10.0
FOLLOW_PITCH_DEADBAND_RATIO = 0.05   # lo mismo para la medida por tamano de caja

# Al acercarse, limita la velocidad segun lo que falta para que el dron frene y se
# pare en la distancia objetivo en vez de embestir.
FOLLOW_APPROACH_SPEED_GAIN = 0.55        # cm/s de tope por cm que falta para el objetivo
FOLLOW_RETREAT_GAIN_MULTIPLIER = 2.5     # da mas agilidad al retroceder si la persona se acerca

# Distancia a la que el dron deja de acercarse usando solo la vision. Es menor que
# la real porque la vision se queda corta (~40 cm); asi sigue avanzando hasta que el
# ToF, mas preciso, toma el mando y para en la distancia buena.
VISION_APPROACH_SETPOINT_CM = 35.0

# Suaviza los cambios de avance entre frames: tras un corte de video, una deteccion
# nueva no debe provocar un aceleron brusco.
FB_SLEW_RATE_PER_FRAME = 8.0

# --- Imagen (tamano del frame de video, en px) ---
FRAME_W = 640
FRAME_H = 480
FRAME_CENTER_X = FRAME_W // 2
FRAME_CENTER_Y = FRAME_H // 2

TARGET_Y_RATIO   = 0.25          # altura ideal de los hombros en la imagen (25% desde arriba)
INTERCEPT_DISTANCE_CM = 60.0     # distancia a la que el dron quiere quedarse de la persona

# --- Sensor ToF frontal (mide la distancia a la persona/pared) ---
FRONT_TOF_WALL_STOP_CM          = 30.0   # mas cerca de esto: se para (posible pared)
FRONT_TOF_INVALID_HYSTERESIS_FRAMES = 8  # frames sin ToF valido antes de fiarse de la caja
FRONT_TOF_DISCONTINUITY_FREEZE_S    = 0.4  # congela el avance un momento tras perder la lectura
# El timeout DEBE ser un int (la libreria lo exige); un float lanzaria error y la
# lectura fallaria siempre. Con 1 s basta: en exito responde en ~0.1 s.
FRONT_TOF_CMD_TIMEOUT_S         = 1
FRONT_TOF_LOOP_INTERVAL_S       = 0.1    # frecuencia de lectura del ToF (10 Hz)
FRONT_TOF_LOG_INTERVAL_S        = 1.0    # cada cuanto imprime diagnostico

# --- Distancia estimada por vision (respaldo del ToF) ---
# Si el ToF falla, se estima la distancia por el ancho de hombros en la imagen
# (regla de la camara pin-hole). FOCAL_PX se calibro comparando con el ToF real.
VISION_DISTANCE_ENABLED   = True
PERSON_SHOULDER_WIDTH_CM  = 40.0   # ancho de hombros medio de un adulto
FOCAL_PX                  = 460.0  # focal efectiva de la camara del Tello a 640 px de ancho
VISION_MIN_SHOULDER_PX    = 12.0   # menos px de hombro: medida poco fiable, se descarta
VISION_DIST_MIN_CM        = 30.0   # recorte de cordura (min)
VISION_DIST_MAX_CM        = 600.0  # recorte de cordura (max)
VISION_DIST_EMA_ALPHA     = 0.40   # suavizado de la distancia por vision

# Suavizado de la posicion de la persona entre frames (0-1; mas alto = mas reactivo)
TARGET_EMA_ALPHA    = 0.40

# --- Deteccion de personas (YOLO) y seguimiento de IDs ---
POSE_IMGSZ          = 640   # resolucion de inferencia; debe coincidir con estacion_tierra.POSE_IMGSZ
YOLO_FRAME_STRIDE   = 1      # analizar 1 de cada N frames; 1 = todos (IDs mas estables)
CONF_THRESHOLD      = 0.45   # confianza minima para aceptar una deteccion
MIN_BBOX_W          = 30     # descarta cajas mas estrechas que esto (px)
MIN_BBOX_H          = 50     # descarta cajas mas bajas que esto (px)

# Tracker que da un id estable a cada persona. El follow se ancla a un id y sigue
# SIEMPRE a esa persona aunque aparezcan otras; solo lo suelta al pasar a SEARCH.
TRACKER_CFG         = 'botsort.yaml'

# --- Control por gestos (solo lo puede hacer la persona seguida) ---
GESTURE_CONTROL_ENABLED   = True
GESTURE_CONFIRM_FRAMES    = 5      # frames seguidos con el gesto para darlo por bueno
GESTURE_WRIST_MARGIN_PX   = 20.0   # cuanto ha de subir la muneca sobre el hombro para valer

# --- Perdida del objetivo ---
TARGET_LOST_GRACE_S = 5   # segundos quieto (HOVER) antes de ponerse a buscar (SEARCH)
TRACKING_MISS_HYSTERESIS_FRAMES = 3  # fallos sueltos de deteccion que se toleran sin dar por perdido

# --- Busqueda (SEARCH) y bucle de control ---
SEARCH_SPIN_VELOCITY_DEG_S = 20    # velocidad de giro mientras busca (deg/s)
RC_LOOP_INTERVAL_S         = 0.05  # periodo del bucle que envia RC al dron (20 Hz)

# Tope de FPS del bucle de video. Mas FPS = mas detecciones/seg y control mas fino;
# la GPU potente lo permite. El ToF va aparte a 10 Hz, asi no lo penaliza.
VIDEO_LOOP_TARGET_FPS = 60


# ============================================================
# ORBIT CONTROLLER — constantes
# ============================================================

# Antes de girar, la orbita se coloca a la distancia buena (APPROACH) y se alinea
# de frente (ALIGN); estas constantes marcan esas transiciones.
ORBIT_RADIUS_CM              = 100.0   # distancia deseada persona-dron
ORBIT_ALIGN_ENTER_CM         = 115.0   # ToF para pasar de acercarse a alinearse
ORBIT_ALIGN_EXIT_CM          = 135.0   # ToF para volver a acercarse si se aleja
ORBIT_STABLE_TOF_MARGIN_CM   = 8.0     # margen de ToF para dar la distancia por estable
ORBIT_ALIGN_PX_THRESH        = 30      # error de centrado maximo (px) para considerarse alineado
ORBIT_ALIGN_STABLE_FRAMES    = 12      # frames seguidos estables para empezar a orbitar
ORBIT_ALIGN_TIMEOUT_S        = 8.0     # tiempo maximo alineando antes de reintentar

# Movimiento de giro alrededor de la persona (strafe lateral + yaw acompanando)
ORBIT_TANGENTIAL_SPEED       = 24      # velocidad base de giro lateral (mas bajo = vuelta mas suave)
ORBIT_LR_MAX_VELOCITY        = 45      # tope de velocidad lateral (deja margen al PID de centrado)
ORBIT_RAMP_STEP              = 0.03    # arranque gradual del giro (~1 s hasta la velocidad plena)
ORBIT_LR_SLEW_RATE_PER_FRAME = 4.0     # suaviza los cambios de strafe entre frames
ORBIT_YAW_FF_GAIN            = 0.9     # cuanto yaw acompana al strafe para quedar tangente a la persona
ORBIT_RADIAL_FF_GAIN         = 0.10    # empujoncito hacia dentro que compensa la fuga natural hacia afuera
ORBIT_MAX_RADIUS_CM          = 170.0   # (en desuso) tope de ToF; sustituido por radio+deriva
ORBIT_LOST_FRAMES            = 6       # frames sin ver a la persona para darla por 'perdida'
ORBIT_LOST_GRACE_S           = 3.0     # gracia estando 'perdida' antes de ponerse a buscar
ORBIT_WALL_STOP_CM           = 35.0    # freno anti-choque de la orbita (mas conservador)

# Radio automatico: la orbita usa como radio la distancia real a la que empieza
# (la captura del ToF en la primera lectura buena), no un valor fijo del slider.
ORBIT_RADIUS_LATCH_TIMEOUT_S = 2.0     # espera max. de un ToF valido antes de usar el fallback
ORBIT_RADIUS_MIN_CM          = 45.0    # radio minimo de cordura (por encima del freno anti-choque)
ORBIT_RADIUS_MAX_CM          = 160.0   # radio maximo de cordura (dentro del rango fiable del ToF)
ORBIT_MAX_DRIFT_CM           = 70.0    # cuanto puede alejarse del radio antes de volver a acercarse
ORBIT_ALIGN_ENTER_MARGIN_CM  = 15.0    # margen sobre el radio para pasar a alinearse

# Respaldo cuando no hay ToF: se mide la cercania por el tamano de la caja
ORBIT_CLOSENESS_SETPOINT = 0.55        # radio ~100 cm equivale a una caja que ocupa ~55% del alto

# Mantener el radio mientras gira. El ToF es la senal principal (es el unico que
# nota "demasiado cerca"); el tamano de la caja queda de respaldo si el ToF calla.
ORBIT_RADIAL_DEADBAND_CM     = 10.0    # banda muerta del error de distancia (no corrige dentro de ella)
ORBIT_FB_SLEW_RATE_PER_FRAME = 5.0     # suaviza el avance/retroceso cuando el ToF parpadea
ORBIT_DIST_EMA_ALPHA         = 0.40    # suavizado de la distancia radial para no "perseguir" el ruido del ToF


# Controlador de los modos Follow y Orbit. Al crearse lanza los tres hilos que lo
# hacen funcionar (video, envio de RC y lectura del ToF) y sigue a la persona segun
# una maquina de estados: INTERCEPTING (siguiendo) -> HOVER (quieto si la pierde) ->
# SEARCHING (girando para reencontrarla). La distancia la da el ToF y, si falla, la
# vision. El mismo objeto sirve para orbitar activando activate_orbit().
class FollowController:

    # Guarda el dron, inicializa todo el estado (PIDs, flags, contadores) y arranca
    # los tres hilos daemon: lectura del ToF, envio de RC y bucle de video.
    def __init__(self, tello_ref, pose_model=None):
        self._tello = tello_ref
        self._active = True
        self.on_stream_dead = None  # callable() — se llama cuando el stream de vídeo muere

        # Modelo de poses YOLO. Se INYECTA desde estacion_tierra en vez de importarlo
        # aqui: la ET corre como __main__ y ese import re-ejecutaria todo el fichero.
        # De respaldo, lo busca via sys.modules por si se crea sin pasar el modelo.
        if pose_model is None:
            import sys
            _mm = sys.modules.get('__main__')
            if _mm is None or not hasattr(_mm, 'pose_model'):
                _mm = sys.modules.get('estacion_tierra')
            pose_model = getattr(_mm, 'pose_model', None) if _mm else None
        self._pose_model = pose_model

        # ── Cerrojo del SDK ──
        # Se comparte con TelloDron para que las lecturas del ToF no crucen sus
        # respuestas con otros comandos (telemetria, stream, flip) por el mismo socket.
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
    # Hilo que pregunta al sensor ToF frontal su distancia (comando 'EXT tof?') una y
    # otra vez a 10 Hz y guarda el valor en cm en self.front_tof_cm.
    def _tof_loop(self):
        while self._active:
            err_kind = None   # tipo de fallo del ciclo (para el log de diagnostico)
            raw = None
            ok_cm = None      # cm leidos en este ciclo (para el log de exito)
            try:
                # Si el Tello perdio el WiFi, otro hilo pudo dejar el socket a None:
                # comprobarlo antes de tocarlo para no petar.
                inner = getattr(self._tello, '_tello', None)
                if inner is None:
                    err_kind = 'no_inner'
                    time.sleep(FRONT_TOF_LOOP_INTERVAL_S)
                    continue
                with self._sdk_lock:
                    # Vaciar la cola de respuestas antes de preguntar: es compartida
                    # con otros comandos y podria quedar una respuesta ajena que
                    # leeriamos por error en vez de la del ToF.
                    try:
                        inner.get_own_udp_object()['responses'].clear()
                    except Exception:
                        pass
                    # El timeout debe ser int (lo exige la libreria); int() lo asegura.
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
                    with self._tof_lock:
                        # Si veniamos de una lectura valida y ahora es -1, el dron
                        # cruzo un borde: congela el avance un momento para no dar tirones.
                        if self._tof_cm_prev > 0 and new_cm == -1.0:
                            self._front_tof_freeze_until = time.time() + FRONT_TOF_DISCONTINUITY_FREEZE_S
                        self._tof_cm_prev = new_cm
                        self.front_tof_cm = new_cm
            except Exception as e:
                err_kind = f'exc:{type(e).__name__}'
                self._tof_fail_count += 1
            # Log de diagnostico limitado a ~1/s: registra tanto los fallos como los
            # aciertos, con el valor leido y los contadores de exito/fallo.
            t = time.time()
            if t - self._tof_last_log_t >= FRONT_TOF_LOG_INTERVAL_S:
                self._tof_last_log_t = t
                if err_kind is not None:
                    print(f'[FOLLOW][ToF] sin lectura ({err_kind}) '
                          f'raw={raw!r} ok={self._tof_ok_count} fail={self._tof_fail_count}')
                else:
                    print(f'[FOLLOW][ToF] OK {ok_cm:.1f}cm raw={raw!r} '
                          f'ok={self._tof_ok_count} fail={self._tof_fail_count}')
            time.sleep(FRONT_TOF_LOOP_INTERVAL_S)

    @staticmethod
    # Saca los milimetros de la respuesta del ToF ('tof 1234'), o None si no la hay.
    # Exige el texto 'tof' seguido del numero para no confundir un mensaje de timeout
    # ('...after 1 seconds') o una respuesta de otro comando con una lectura real.
    def _parse_tof_mm(raw):
        if not raw:
            return None
        s = raw.decode('utf-8', 'ignore') if isinstance(raw, (bytes, bytearray)) else str(raw)
        m = re.search(r'tof[\s:]*(\d+)', s, re.IGNORECASE)
        return int(m.group(1)) if m else None

    # ------------------------------------------------------------------ RC loop
    # Hilo que envia al dron, 20 veces por segundo, el ultimo comando de movimiento
    # (lr, fb, ud, yaw) que el bucle de video haya calculado.
    def _rc_loop(self):
        fail_count = 0
        while self._active:
            t0 = time.time()
            with self._rc_lock:
                lr, fb, ud, yaw = self._rc
            try:
                # rc() no espera respuesta, asi que no toma el cerrojo del SDK: el
                # bucle a 20 Hz no debe quedarse esperando detras de un tof?/wifi?.
                self._tello.rc(lr, fb, ud, yaw)
                fail_count = 0
            except Exception as e:
                fail_count += 1
                print(f'[FOLLOW] rc error: {e}')
                # Si falla varias veces seguidas (p.ej. WiFi caido), para el controller
                # en vez de seguir mandando RC sin efecto; el video avisara del corte.
                if fail_count >= 3:
                    print('[FOLLOW] rc fallo persistente, deteniendo controller.')
                    with self._rc_lock:
                        self._rc = [0, 0, 0, 0]
                    self._active = False
                    break
            elapsed = time.time() - t0
            time.sleep(max(0.0, RC_LOOP_INTERVAL_S - elapsed))

    # ------------------------------------------------------------------ Detección YOLO
    # Pasa el frame por YOLO-pose y devuelve la lista de personas detectadas, cada una
    # con su caja, la altura de sus hombros, su id de seguimiento y sus keypoints.
    # El frame debe entrar en BGR: YOLO asume ese orden y lo invierte por dentro.
    def _detect_persons(self, frame_bgr, frame_w=FRAME_W, frame_h=FRAME_H):
        pose_model = self._pose_model
        if pose_model is None:
            raise RuntimeError('pose_model no inyectado en FollowController')
        # persist=True mantiene los ids del tracker entre frames; classes=[0] = personas
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

    # Elige a que persona seguir de entre las detectadas:
    #  - Si hay un objetivo anclado (target_id), devuelve ESA persona y ninguna otra;
    #    si no aparece este frame, devuelve None (lo gestiona la gracia de perdida).
    #  - Sin objetivo anclado, coge la mas cercana al ultimo punto conocido o, si no
    #    lo hay, la de caja mas grande (la mas cercana a la camara).
    def _select_best_person(self, persons, last_point_px, target_id=None):
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
    # Estima la distancia (cm) a la persona por el ancho de sus hombros en la imagen:
    # cuanto mas juntos se ven, mas lejos esta. Respaldo del ToF. None si no es fiable.
    @staticmethod
    def _estimate_distance_cm(kp_xy):
        if kp_xy is None or len(kp_xy) <= 6:
            return None
        lsx, lsy = float(kp_xy[5][0]), float(kp_xy[5][1])
        rsx, rsy = float(kp_xy[6][0]), float(kp_xy[6][1])
        # (0,0) significa que YOLO no detecto ese hombro
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
    # Ajusta la velocidad de avance/retroceso: al acercarse la limita para frenar y
    # pararse en la distancia objetivo; al retroceder la aumenta para apartarse rapido.
    @staticmethod
    def _shape_pitch_fb(fb: float, dist_cm: float,
                        setpoint_cm: float = INTERCEPT_DISTANCE_CM) -> float:
        if fb > 0:
            cap = max(0.0, FOLLOW_APPROACH_SPEED_GAIN * (dist_cm - setpoint_cm))
            return min(fb, cap)
        if fb < 0:
            return max(fb * FOLLOW_RETREAT_GAIN_MULTIPLIER, -FB_MAX_VELOCITY)
        return fb

    # ------------------------------------------------------------------ Gestos
    # Mira si la persona levanta un brazo o los dos y devuelve el gesto correspondiente
    # ('left_up'/'right_up'/'both_up'), o None. Un brazo esta "arriba" si su muneca
    # queda por encima del hombro. Izquierda/derecha son las de la imagen.
    def _detect_gesture(self, kp_xy):
        if kp_xy is None or len(kp_xy) <= 10:
            return None

        # ¿esta la muneca por encima del hombro? (con un margen para evitar falsos)
        def _up(wrist_idx, shoulder_idx):
            wx, wy = float(kp_xy[wrist_idx][0]), float(kp_xy[wrist_idx][1])
            sx, sy = float(kp_xy[shoulder_idx][0]), float(kp_xy[shoulder_idx][1])
            # (0,0) = keypoint no visible → no cuenta como brazo arriba
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

    # Olvida el gesto actual y el que se estaba confirmando
    def _reset_gesture_state(self):
        self._gesture           = None
        self._gesture_candidate = None
        self._gesture_count     = 0
        self._gesture_paused    = False

    # ------------------------------------------------------------------ Vídeo loop principal
    # Envoltura del bucle de video: si el bucle interno peta, lo registra y lo reanuda
    # en vez de morir en silencio (que dejaria el modo colgado).
    def _video_loop(self):
        import traceback
        while self._active:
            try:
                self._video_loop_inner()
            except Exception:
                print('[FOLLOW] excepcion en _video_loop:')
                traceback.print_exc()
                time.sleep(0.1)

    # Bucle de video: es el que de verdad sigue a la persona. En cada frame detecta,
    # elige objetivo, calcula el movimiento (Follow u Orbit segun el modo) y deja el
    # comando RC listo para que _rc_loop lo envie.
    def _video_loop_inner(self):
        frame_count        = 0
        consecutive_none   = 0
        detected_persons   = []
        prev_t             = time.time()
        # Medidor de FPS (solo para diagnostico por consola)
        _fps_t0            = time.time()
        _fps_frames        = 0
        _fps_last          = 0.0

        while self._active:
            frame_rgb = self._tello.get_frame()

            if frame_rgb is None:
                consecutive_none += 1
                if consecutive_none > 300:
                    print('[FOLLOW] Stream muerto, deteniendo.')
                    # Poner el RC a cero antes de salir: si no, _rc_loop seguiria
                    # mandando el ultimo movimiento hasta que el Tello lo corte solo.
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

            # Lee el modo (Follow u Orbit) una vez por frame, para no mezclar los dos
            # si el usuario lo cambia justo a mitad de calculo.
            orbit_mode = self._orbit_mode

            # Altura ideal de los hombros en la imagen (25% desde arriba)
            target_setpoint_y_px = int(actual_h * TARGET_Y_RATIO)

            # ── Detección YOLO ──────────────────────────────────────
            if frame_count % YOLO_FRAME_STRIDE == 0:
                try:
                    detected_persons = self._detect_persons(frame_bgr, actual_w, actual_h)
                except Exception as e:
                    print(f'[FOLLOW] error deteccion YOLO: {e}')
                    # Vaciar la lista para no seguir persiguiendo a la persona del
                    # frame anterior como si fuera un fantasma.
                    detected_persons = []

            # ── Selección del mejor objetivo ────────────────────────
            last_point = (
                (self._target_smoothed_x_px, self._target_smoothed_y_px)
                if self._target_ema_initialized else None
            )
            # El anclaje por id solo se usa en Follow; en Orbit va a None
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
                # Punto a seguir: en X el centro de la caja; en Y los hombros (o el
                # centro si no se ven).
                raw_cx = float(x1 + bw / 2.0)
                raw_cy = shoulder_cy if shoulder_cy is not None else float(y1 + bh / 2.0)
                target_x_px = int(raw_cx)
                target_y_px = int(raw_cy)
                tracked_shoulder_cy = shoulder_cy
                tracked_kp = kp_xy
                tracking_target_raw = True
                # Al pillar objetivo por primera vez, se ancla su id: a partir de ahi
                # se sigue solo a esa persona, aunque aparezcan otras.
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
            # Guarda a que lado esta la persona y suaviza su posicion (EMA). Se hace en
            # los dos modos: Orbit tambien los usa para buscar y centrar.
            if tracking_target_raw:
                # Lado: persona a la derecha → +1; a la izquierda → -1. Sirve para que,
                # si la pierde, gire a buscarla hacia donde estaba.
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
            # Solo la persona seguida manda. El gesto debe repetirse varios frames
            # seguidos para valer. Por ahora: brazos arriba (both_up) = pausar el follow.
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

                self._search_state = 'none'
                self._follow_status = 'intercepting'

                # ── Pausa por gesto (ambos brazos arriba) ────────────
                # Se queda quieto (sin soltar el objetivo) mientras la persona mantenga
                # los dos brazos arriba. Resetea los integrales para no acumular error.
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

                # Suaviza el "tamano" de la persona (alto de la caja): sirve de
                # respaldo para medir la distancia cuando no hay ToF.
                if tracking_target_raw and best is not None:
                    x1, y1, x2, y2, *_ = best
                    raw_closeness = (y2 - y1) / float(actual_h)
                    if not self._closeness_ema_initialized:
                        self._closeness_smoothed = raw_closeness
                        self._closeness_ema_initialized = True
                    else:
                        self._closeness_smoothed = (TARGET_EMA_ALPHA * raw_closeness +
                                                    (1 - TARGET_EMA_ALPHA) * self._closeness_smoothed)

                # Distancia estimada por vision (ancho de hombros), suavizada. Respaldo del ToF.
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

                # ── Pitch PID: avance/retroceso para mantener la distancia ──
                # Usa la mejor fuente de distancia disponible, en este orden:
                #   1) ToF fisico (el mas preciso de cerca)
                #   2) distancia por vision (cm) si el ToF calla
                #   3) tamano de la caja, como ultimo recurso
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
                    # Con vision usa un objetivo mas cercano para seguir acercandose;
                    # el ToF, al activarse, hara la parada fina en la distancia real.
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
                    # Ultimo recurso: usa el tamano de la caja como medida de cercania
                    # (crece al acercarse). Objetivo: que ocupe ~45% del alto del frame.
                    CLOSENESS_SETPOINT = 0.45
                    error_pitch = self._closeness_smoothed - CLOSENESS_SETPOINT
                    # Sembrar error_last al entrar en bbox evita un tiron del termino D
                    if self._pitch_source_last != 'bbox':
                        self.pitch_bbox_pid.error_last = error_pitch
                    fb = self.pitch_bbox_pid.compute(error_pitch, dt)
                    # Banda muerta (en proporcion): igual que con el ToF, evita oscilar
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
                # Objetivo perdido de verdad: suelta el id para poder engancharse a
                # cualquier persona que aparezca mientras gira buscando.
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
                    # Se cuenta la vuelta por tiempo (no por frames), que es mas fiable
                    elapsed_spin = time.time() - self._search_spin_start_t
                    if elapsed_spin * SEARCH_SPIN_VELOCITY_DEG_S >= 360.0:
                        # 360° completados → parar, esperar nueva detección
                        yaw = 0
                        self._search_state = 'none'
                        self._search_spin_start_t = 0.0

            # ════════════════════════════════════════════════════════════════════
            # MAQUINA DE ESTADOS DE ORBIT — solo se ejecuta en modo Orbit; reemplaza
            # el movimiento (lr/fb/ud/yaw) que hubiera calculado el Follow.
            # ════════════════════════════════════════════════════════════════════

            if orbit_mode:
                # Descarta lo que calculo el Follow y parte de cero
                lr = 0; fb = 0; ud = 0; yaw = 0

                # Suaviza el tamano de la caja (cercania) tambien aqui: en Orbit no se
                # ejecuta la rama Follow, asi que hay que calcularlo de nuevo.
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

                # ── Distancia a la persona (ToF; si falla, tamano de la caja) ──
                if (self._last_valid_front_tof_cm > 0 and
                        self._tof_invalid_count < FRONT_TOF_INVALID_HYSTERESIS_FRAMES):
                    orbit_dist_cm = (current_tof_cm if valid_front_tof
                                    else self._last_valid_front_tof_cm)
                    orbit_dist_source = 'tof'
                    self._orbit_tof_display = orbit_dist_cm
                elif self._closeness_ema_initialized:
                    # Sin ToF: convierte el tamano de la caja a cm aproximados
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

                # ── Maquina de estados de la orbita ───────────────────────────
                # Recorrido: search (busca a la persona y fija el radio) -> approach
                # (se acerca) -> align (se coloca de frente) -> orbit (gira). Si la
                # pierde pasa a lost y, si sigue sin verla, vuelve a search.

                if self._orbit_state == 'search':
                    # SEARCH: espera a ver a la persona y fija el radio de giro
                    self._orbit_status = 'searching'
                    self._orbit_ramp = 0.0
                    self.tangential_pid.reset_integral()
                    self.tangential_pid.error_last = 0.0

                    if tracking_target and not self._orbit_radius_latched:
                        # Radio automatico: se fija a la distancia actual a la persona,
                        # midiendola con el ToF (la fuente mas fiable).
                        if (self._last_valid_front_tof_cm > 0 and
                                self._tof_invalid_count < FRONT_TOF_INVALID_HYSTERESIS_FRAMES):
                            self._orbit_radius_cm = max(
                                ORBIT_RADIUS_MIN_CM,
                                min(ORBIT_RADIUS_MAX_CM, self._last_valid_front_tof_cm))
                            self._orbit_radius_latched = True
                            # Pasa a ALIGN (centrarse) y no directo a ORBIT: como el radio
                            # es la distancia actual, solo hace falta encararla.
                            self._orbit_state = 'align'
                            self._orbit_status = 'aligning'
                            self._orbit_align_start_time = now
                            self._orbit_align_stable_count = 0
                            self.pitch_pid.reset_integral()
                            self.yaw_pid.reset_integral()
                            print(f'[ORBIT] Radio fijado a {self._orbit_radius_cm:.0f}cm '
                                  f'(ToF)')
                        elif self._closeness_ema_initialized and self._closeness_smoothed > 0.01:
                            # Sin ToF fiable pero con tamano de caja: estima el radio a
                            # partir de el y pasa a ALIGN sin esperar al timeout.
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
                        # Radio ya fijado (reencuentro tras perderla): vuelve por APPROACH
                        self._orbit_state = 'approach'
                        self._orbit_status = 'approach'
                        self.pitch_pid.reset_integral()
                        self.pitch_bbox_pid.reset_integral()
                    else:
                        # Sin persona a la vista: gira despacio buscandola
                        spin_sign = self._last_target_side if self._last_target_side != 0 else 1
                        yaw = spin_sign * SEARCH_SPIN_VELOCITY_DEG_S
                        fb = 0; lr = 0; ud = 0

                elif self._orbit_state == 'approach':
                    # APPROACH: se acerca hasta quedar a la distancia de orbita
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

                            # Ya bastante cerca del radio: pasa a alinearse
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
                    # ALIGN: se coloca de frente (centra el yaw) antes de empezar a girar
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

                        # Corrige la distancia solo si se aparta mas que el margen que
                        # cuenta como "estable" (si no, no tocar y dejar que se estabilice).
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
                                # Ya alineado y estable: empieza a orbitar. Fija el radio a
                                # la distancia real de ahora, para mantenerla mientras gira.
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
                    # ORBIT: gira alrededor (strafe lateral) manteniendo el radio
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

                        # Yaw = giro anticipado (para no perder de vista a la persona
                        # mientras se desliza de lado) + correccion PID para centrarla.
                        # El giro va en sentido contrario al strafe y se refuerza cuanto
                        # menor es el radio (en circulos cerrados hace falta girar mas).
                        error_yaw = self._target_smoothed_x_px - frame_center_x
                        yaw_ff = (-self._orbit_sign * ORBIT_YAW_FF_GAIN
                                  * (ORBIT_RADIUS_CM / max(1.0, self._orbit_radius_cm))
                                  * self._orbit_tangential_ff * self._orbit_ramp)
                        yaw = int(round(yaw_ff + self.yaw_pid.compute(error_yaw, dt)))
                        yaw = max(-YAW_MAX_VELOCITY, min(YAW_MAX_VELOCITY, yaw))

                        # Strafe lateral = velocidad base de giro (con arranque suave) +
                        # una correccion para mantener a la persona centrada al orbitar.
                        tangential_correction = self.tangential_pid.compute(
                            error_yaw, dt)
                        lr = int(round(
                            self._orbit_sign * self._orbit_tangential_ff * self._orbit_ramp
                            + tangential_correction
                        ))
                        lr = max(-ORBIT_LR_MAX_VELOCITY, min(ORBIT_LR_MAX_VELOCITY, lr))

                        # Avance/retroceso para mantener el radio con el ToF: si esta
                        # demasiado cerca retrocede, si esta demasiado lejos avanza.
                        if orbit_dist_source != 'none':
                            # Suaviza la distancia antes de usarla, para que el ruido del
                            # ToF no haga oscilar el radio.
                            if not self._orbit_dist_initialized:
                                self._orbit_dist_smoothed = orbit_dist_cm
                                self._orbit_dist_initialized = True
                            else:
                                self._orbit_dist_smoothed = (
                                    ORBIT_DIST_EMA_ALPHA * orbit_dist_cm +
                                    (1 - ORBIT_DIST_EMA_ALPHA) * self._orbit_dist_smoothed)
                            dist_for_radial = self._orbit_dist_smoothed
                            error_dist = self._orbit_radius_cm - dist_for_radial

                            # Si se aleja demasiado del radio, vuelve a 'align' para
                            # recolocarse antes de seguir girando.
                            if dist_for_radial > self._orbit_radius_cm + ORBIT_MAX_DRIFT_CM:
                                self._orbit_state = 'align'
                                self._orbit_ramp = 0.0
                                self._orbit_align_start_time = now
                                self._orbit_align_stable_count = 0
                                self._orbit_lost_count = 0
                                self.pitch_pid.reset_integral()
                                self.yaw_pid.reset_integral()

                            if self._pitch_source_last != 'tof_orbit':
                                self.pitch_pid.error_last = error_dist
                            fb = self.pitch_pid.compute(error_dist, dt)
                            # Banda muerta: si esta casi en el radio, no corregir (no temblar)
                            if abs(error_dist) < ORBIT_RADIAL_DEADBAND_CM:
                                fb = 0.0

                            # Empujoncito hacia dentro que compensa la tendencia natural a
                            # abrirse al girar de lado.
                            fb += (ORBIT_RADIAL_FF_GAIN
                                   * self._orbit_tangential_ff * self._orbit_ramp)
                            fb = max(-FB_MAX_VELOCITY, min(FB_MAX_VELOCITY, fb))
                        else:
                            fb = 0
                            self.pitch_pid.reset_integral()

                        # Freno anti-choque: si esta muy cerca, solo deja alejarse (fb<=0).
                        # No corta el strafe lateral, que es seguro (el sensor mira a la
                        # persona, no hacia donde el dron se desliza).
                        if valid_front_tof and current_tof_cm <= ORBIT_WALL_STOP_CM:
                            fb = min(0, fb)  # solo permite alejarse, no acercarse
                            self.pitch_pid.reset_integral()

                        # Suaviza los cambios de strafe y avance entre frames para que la
                        # vuelta no de tirones cuando el ToF o la deteccion parpadean.
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
                    # LOST: dejo de verla; me quedo quieto un rato por si reaparece
                    self._orbit_status = 'lost'
                    self._orbit_ramp = 0.0
                    lr = 0; fb = 0; yaw = 0

                    if tracking_target:
                        # La vuelvo a ver: retomo por APPROACH
                        self._orbit_lost_count = 0
                        self._orbit_state = 'approach'
                        self.pitch_pid.reset_integral()
                        self.yaw_pid.reset_integral()
                    elif now - self._orbit_lost_start_time > ORBIT_LOST_GRACE_S:
                        # Se acabo la espera: vuelvo a buscar (SEARCH)
                        self._orbit_state = 'search'

                elif self._orbit_state == 'hover_safe':
                    # HOVER_SAFE: parada de emergencia (se queda quieto)
                    self._orbit_status = 'hover_safe'
                    lr = 0; fb = 0; yaw = 0; ud = 0
                    self._orbit_ramp = 0.0
                    self.altitude_pid.reset_integral()

                # El "freeze" del ToF que usa Follow NO se aplica en Orbit: aqui frenaria
                # el avance justo al perder a la persona; la orbita ya tiene su propio
                # freno anti-choque (ORBIT_WALL_STOP_CM).

            # Recuerda que fuente de distancia se uso, para el siguiente frame. En Orbit
            # ya lo hacen las ramas internas, asi que aqui solo para Follow.
            if not orbit_mode:
                self._pitch_source_last = pitch_source

            # Suaviza los saltos de avance (solo Follow): tras un corte de video, una
            # deteccion que reaparece de golpe no debe provocar un aceleron.
            if not orbit_mode:
                delta_fb = fb - self._fb_prev
                if delta_fb > FB_SLEW_RATE_PER_FRAME:
                    fb = self._fb_prev + FB_SLEW_RATE_PER_FRAME
                elif delta_fb < -FB_SLEW_RATE_PER_FRAME:
                    fb = self._fb_prev - FB_SLEW_RATE_PER_FRAME
            self._fb_prev = fb

            # Deja el comando de movimiento listo para que _rc_loop lo envie al dron
            with self._rc_lock:
                self._rc = [int(round(lr)), int(round(fb)),
                            int(round(ud)), int(round(yaw))]

            # ── Imagen de depuracion (lo que se ve en el stream) ─────
            # Dibuja la caja de la persona y los puntos de referencia sobre el frame
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

            # (Se quito el texto tipo HUD a proposito: el stream va limpio, solo con la
            # caja y los circulos.)

            with self._frame_lock:
                out = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)
                self._debug_frame = cv2.resize(out, (640, 480), interpolation=cv2.INTER_LINEAR)
                self._debug_frame_ts = time.time()

            # Log de FPS cada ~2 s (solo para vigilar el rendimiento por consola)
            _fps_frames += 1
            _dt_fps = time.time() - _fps_t0
            if _dt_fps >= 2.0:
                _fps_last = _fps_frames / _dt_fps
                print(f'[FOLLOW] video loop ~{_fps_last:.1f} FPS '
                      f'(stride={YOLO_FRAME_STRIDE}, imgsz={POSE_IMGSZ})')
                _fps_t0 = time.time()
                _fps_frames = 0

            # Limita el bucle a VIDEO_LOOP_TARGET_FPS; si la GPU no llega, corre a su ritmo
            time.sleep(max(0.0, (1.0 / VIDEO_LOOP_TARGET_FPS) - (time.time() - _now_t)))

    # ------------------------------------------------------------------ API pública
    # Devuelve la ultima imagen de depuracion (con la caja dibujada). Si max_age_s se
    # pasa y la imagen es mas vieja que eso, devuelve None (el bucle se atasco) para
    # que quien la pida muestre el video en vivo en su lugar.
    def get_debug_frame(self, max_age_s: float = None):
        with self._frame_lock:
            if max_age_s is not None and (time.time() - self._debug_frame_ts) > max_age_s:
                return None
            return self._debug_frame

    # Detiene el controller: corta los hilos, espera a que terminen y deja el dron quieto
    def stop(self):
        self._active = False
        # Esperar a que los hilos mueran de verdad (evita hilos zombi que impidan
        # reiniciar Follow/Orbit despues).
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

    # Deja todo el estado a cero (PIDs, distancias, contadores, FSM) para empezar limpio
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

    # Pasa el controller a modo Orbit. Con radius_cm=None (por defecto) el radio es
    # automatico: se fija a la distancia actual a la persona. Si se pasa un numero, se
    # usa ese radio fijo. clockwise elige el sentido de giro.
    def activate_orbit(self, radius_cm: float | None = None,
                    clockwise: bool = True) -> None:
        # Se prepara TODO el estado de la orbita antes de encender el flag _orbit_mode
        # (que se pone el ultimo): asi el bucle de video nunca ve el modo activo con el
        # estado a medio configurar.
        if radius_cm is None:
            # Auto: el radio se fija luego, en 'search', con el primer ToF valido
            self._orbit_radius_cm = ORBIT_RADIUS_CM   # valor provisional hasta entonces
            self._orbit_radius_latched = False
        else:
            self._orbit_radius_cm = radius_cm
            self._orbit_radius_latched = True
        self._orbit_search_start_time = time.time()
        # Sentido del strafe: en horario (CW) el dron se desplaza a su izquierda (lr<0)
        # para rodear a la persona; de ahi el signo -1.
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
        # Encender el modo como ultimo paso (ver comentario de arriba)
        self._orbit_mode = True
        radio_str = f'{radius_cm}cm' if radius_cm is not None else 'auto (distancia actual)'
        print(f'[ORBIT] Activado — radio={radio_str}, '
            f'dir={"CW" if clockwise else "CCW"}')

    # Apaga el modo Orbit y vuelve al Follow normal
    def deactivate_orbit(self) -> None:
        # Deja el RC a cero y limpia el estado antes de bajar el flag, para que el
        # bucle de video retome Follow ya con todo limpio.
        with self._rc_lock:
            self._rc = [0, 0, 0, 0]
        self._orbit_state = 'search'
        self._orbit_ramp = 0.0
        self._orbit_status = 'off'
        self._orbit_tof_display = -1.0
        self._orbit_mode = False
        print('[ORBIT] Desactivado — volviendo a Follow')
