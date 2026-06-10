import threading
import time
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
GAINS_FORWARD_BACK_TOF_PID  = (-0.55,  -0.03,  -0.60)
# Forward/back bbox: error en ratio → velocidad fb cm/s
GAINS_FORWARD_BACK_BBOX_PID = (-70.0, -8.0,  -150.0)
# Límites de velocidad
YAW_MAX_VELOCITY      = 40
UD_MAX_VELOCITY       = 30
FB_MAX_VELOCITY       = 30

# Frame
FRAME_W = 640
FRAME_H = 480
FRAME_CENTER_X = FRAME_W // 2
FRAME_CENTER_Y = FRAME_H // 2

# Target vertical setpoint: hombros en 25% desde arribaS
TARGET_Y_RATIO   = 0.25

# Distancia de intercepción (stop ToF)
INTERCEPT_DISTANCE_CM = 80.0

# ToF
FRONT_TOF_WALL_STOP_CM          = 30.0   # pared peligrosa → fb=0
FRONT_TOF_INVALID_HYSTERESIS_FRAMES = 8  # frames sin ToF antes de caer a bbox
FRONT_TOF_DISCONTINUITY_FREEZE_S    = 0.4  # s congelando fb tras salto válido→-1

# EMA
TARGET_EMA_ALPHA    = 0.25

# Detección / tracking
YOLO_FRAME_STRIDE   = 6
CONF_THRESHOLD      = 0.45
MIN_BBOX_W          = 30
MIN_BBOX_H          = 50

# Pérdida de objetivo
TARGET_LOST_GRACE_S = 5   # HOVER antes de SEARCH
TRACKING_MISS_HYSTERESIS_FRAMES = 3  # frames dropout que no interrumpen tracking

# Search FSM
SEARCH_SPIN_VELOCITY_DEG_S = 20  # deg/s durante spin
RC_LOOP_INTERVAL_S         = 0.05  # 20 Hz


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

ORBIT_TANGENTIAL_SPEED       = 25      # lr feedforward base [RC units, 0–100]
ORBIT_LR_MAX_VELOCITY        = 35      # límite lr (feedforward + PID)
ORBIT_RAMP_STEP              = 0.06    # rampa: ~17 ciclos (~0.57s) para máximo lr
ORBIT_YAW_FF_GAIN            = 0.7     # escala yaw feedforward relativo a lr tangencial
ORBIT_MAX_RADIUS_CM          = 170.0   # ToF máximo en ORBIT → transición a APPROACH
ORBIT_LOST_FRAMES            = 6       # frames consecutivos sin target → estado 'lost'
ORBIT_LOST_GRACE_S           = 3.0     # gracia en 'lost' antes de 'search'
ORBIT_WALL_STOP_CM           = 35.0    # wall stop específico de Orbit (más conservador)

# Closeness setpoint para Orbit (bbox fallback cuando no hay ToF)
# Radio 100cm ≈ bbox_height_ratio ~0.55 en Tello con persona adulta
ORBIT_CLOSENESS_SETPOINT = 0.55


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

        # ── Hysteresis de detección ───────────────────────────────────
        self._tracking_miss_count: int = 0

        # ── Pérdida / search ──────────────────────────────────────────
        self._last_target_seen_time:  float = 0.0
        self._last_target_side:       int   = 0   # -1 izq, +1 der, 0 centro
        self._search_state:           str   = 'none'   # 'none' | 'spin'
        self._search_spin_angle_deg:  float = 0.0


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

        # Radio objetivo de órbita en cm
        self._orbit_radius_cm: float = ORBIT_RADIUS_CM

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
            try:
                with self._sdk_lock:
                    raw = self._tello._tello.send_command_with_return('EXT tof?', timeout=0.15)
                if raw and raw.strip().startswith('tof '):
                    mm = int(raw.strip().split()[1])
                    new_cm = -1.0 if mm >= 8190 else mm / 10.0
                    # Guardia diagonal: válido→-1 = drone pasó borde de pared
                    if self._tof_cm_prev > 0 and new_cm == -1.0:
                        self._front_tof_freeze_until = time.time() + FRONT_TOF_DISCONTINUITY_FREEZE_S
                    self._tof_cm_prev = new_cm
                    with self._tof_lock:
                        self.front_tof_cm = new_cm
            except Exception:
                pass
            time.sleep(0.1)

    # ------------------------------------------------------------------ RC loop
    def _rc_loop(self):
        while self._active:
            t0 = time.time()
            with self._rc_lock:
                lr, fb, ud, yaw = self._rc
            try:
                # rc → send_rc_control (sin respuesta): no toca la cola `responses`
                # y NO debe tomar _sdk_lock, o el bucle a 20 Hz se bloquearía detrás
                # de un tof?/wifi? en espera.
                self._tello.rc(lr, fb, ud, yaw)
            except Exception as e:
                print(f'[FOLLOW] rc error: {e}')
            elapsed = time.time() - t0
            time.sleep(max(0.0, RC_LOOP_INTERVAL_S - elapsed))

    # ------------------------------------------------------------------ Detección YOLO
    def _detect_persons(self, frame_bgr, frame_w=FRAME_W, frame_h=FRAME_H):
        """Retorna lista de (x1,y1,x2,y2, shoulder_cy_or_None).

        IMPORTANTE: ultralytics asume que un array numpy viene en BGR (convención
        cv2) y lo invierte internamente a RGB antes de inferir. djitellopy entrega
        los frames en RGB, así que aquí se debe pasar la versión ya convertida a
        BGR (frame_bgr); pasar el RGB crudo intercambia R/B y la detección falla.
        """
        pose_model = self._pose_model
        if pose_model is None:
            raise RuntimeError('pose_model no inyectado en FollowController')
        results = pose_model(frame_bgr, imgsz=320, verbose=False)
        persons = []
        for result in results:
            if result.boxes is None:
                continue
            kps = result.keypoints.xy if result.keypoints is not None else None
            for i, (box, conf) in enumerate(zip(result.boxes.xyxy, result.boxes.conf)):
                if float(conf) < CONF_THRESHOLD:
                    continue
                x1 = max(0, int(box[0]))
                y1 = max(0, int(box[1]))
                x2 = min(int(box[2]), frame_w)
                y2 = min(int(box[3]), frame_h)
                if (x2 - x1) < MIN_BBOX_W or (y2 - y1) < MIN_BBOX_H:
                    continue
                shoulder_cy = None
                if kps is not None and len(kps) > i:
                    kp = kps[i]
                    if len(kp) > 6:
                        lsx, lsy = float(kp[5][0]), float(kp[5][1])
                        rsx, rsy = float(kp[6][0]), float(kp[6][1])
                        if lsx > 0 and rsx > 0:
                            shoulder_cy = (lsy + rsy) / 2.0
                persons.append((x1, y1, x2, y2, shoulder_cy))
        return persons

    def _select_best_person(self, persons, last_point_px):
        """
        Lógica de selección equivalente a select_best_person del proyecto referencia:
        - Si hay last_point_px → más cercana en píxeles (entre las visibles)
        - Si no → mayor área bbox
        """
        if not persons:
            return None
        if last_point_px is None:
            return max(persons, key=lambda p: (p[2]-p[0]) * (p[3]-p[1]))
        lx, ly = last_point_px
        return min(persons, key=lambda p: ((p[0]+p[2])/2 - lx)**2 + ((p[1]+p[3])/2 - ly)**2)

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

        while self._active:
            frame_rgb = self._tello.get_frame()

            if frame_rgb is None:
                consecutive_none += 1
                if consecutive_none > 300:
                    print('[FOLLOW] Stream muerto, deteniendo.')
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

            # Setpoint vertical: hombros al 25% superior del frame
            target_setpoint_y_px = int(actual_h * TARGET_Y_RATIO)

            # ── Detección YOLO (cada STRIDE frames) ─────────────────
            if frame_count % YOLO_FRAME_STRIDE == 0:
                try:
                    detected_persons = self._detect_persons(frame_bgr, actual_w, actual_h)
                except Exception as e:
                    print(f'[FOLLOW] error deteccion YOLO: {e}')

            # ── Selección del mejor objetivo ────────────────────────
            last_point = (
                (self._target_smoothed_x_px, self._target_smoothed_y_px)
                if self._target_ema_initialized else None
            )
            best = self._select_best_person(detected_persons, last_point)
            now  = time.time()

            # ── Punto de tracking raw ────────────────────────────────
            tracking_target_raw = False
            target_x_px = None
            target_y_px = None
            tracked_shoulder_cy = None

            if best is not None:
                x1, y1, x2, y2, shoulder_cy = best
                bw = x2 - x1
                bh = y2 - y1
                # X: centro bbox; Y: hombros si visible, si no centro bbox
                raw_cx = float(x1 + bw / 2.0)
                raw_cy = shoulder_cy if shoulder_cy is not None else float(y1 + bh / 2.0)
                target_x_px = int(raw_cx)
                target_y_px = int(raw_cy)
                tracked_shoulder_cy = shoulder_cy
                tracking_target_raw = True

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
            if not self._orbit_mode and tracking_target:
                if tracking_target_raw:
                    self._last_target_seen_time = now
                    # Actualizar lado del target (para recovery yaw)
                    side = target_x_px - frame_center_x
                    if side > 0:
                        self._last_target_side = 1
                    elif side < 0:
                        self._last_target_side = -1

                self._search_state = 'none'
                self._follow_status = 'intercepting'

                # EMA posición target
                if tracking_target_raw:
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

                # EMA closeness (bbox_height_ratio, igual que proyecto referencia)
                if tracking_target_raw and best is not None:
                    x1, y1, x2, y2, _ = best
                    raw_closeness = (y2 - y1) / float(actual_h)
                    if not self._closeness_ema_initialized:
                        self._closeness_smoothed = raw_closeness
                        self._closeness_ema_initialized = True
                    else:
                        self._closeness_smoothed = (TARGET_EMA_ALPHA * raw_closeness +
                                                    (1 - TARGET_EMA_ALPHA) * self._closeness_smoothed)

                # ── Altitud PID ──────────────────────────────────────
                error_altitude = self._target_smoothed_y_px - target_setpoint_y_px
                ud = self.altitude_pid.compute(error_altitude, dt)

                # ── Yaw PID ──────────────────────────────────────────
                error_yaw = self._target_smoothed_x_px - frame_center_x
                yaw = self.yaw_pid.compute(error_yaw, dt)

                # ── Pitch PID (ToF prioritario / bbox fallback) ──────
                # Fuente ToF: usa hysteresis igual que proyecto referencia
                if (self._last_valid_front_tof_cm > 0 and
                        self._tof_invalid_count < FRONT_TOF_INVALID_HYSTERESIS_FRAMES):
                    pitch_source = 'tof'
                    tof_for_pid = (current_tof_cm if valid_front_tof
                                   else self._last_valid_front_tof_cm)
                    error_pitch = INTERCEPT_DISTANCE_CM - tof_for_pid
                    # Sembrar error_last al entrar en ToF → evita spike D-term
                    if self._pitch_source_last != 'tof':
                        self.pitch_pid.error_last = error_pitch
                    fb = self.pitch_pid.compute(error_pitch, dt)
                    self.pitch_bbox_pid.reset_integral()
                    self._follow_status = 'tof'
                    self._tof_display = tof_for_pid

                elif self._closeness_ema_initialized:
                    pitch_source = 'bbox'
                    # closeness_setpoint: queremos bbox_height_ratio = 0.45
                    # (equivalente a BBOX_HEIGHT_RATIO_SETPOINT del proyecto referencia)
                    CLOSENESS_SETPOINT = 0.45
                    error_pitch = CLOSENESS_SETPOINT - self._closeness_smoothed
                    # Sembrar error_last al entrar en bbox → evita spike D-term
                    if self._pitch_source_last != 'bbox':
                        self.pitch_bbox_pid.error_last = error_pitch
                    fb = self.pitch_bbox_pid.compute(error_pitch, dt)
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
            elif (not self._orbit_mode and
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
            elif not self._orbit_mode:
                self._follow_status = 'searching'
                self._tof_display   = -1.0
                self._target_ema_initialized    = False
                self._closeness_ema_initialized = False
                self.altitude_pid.reset_integral()
                self.pitch_pid.reset_integral()
                self.pitch_bbox_pid.reset_integral()
                self.yaw_pid.reset_integral()
                fb  = 0
                lr  = 0
                ud  = 0

                if self._search_state == 'none':
                    self._search_state = 'spin'
                    self._search_spin_angle_deg = 0.0

                if self._search_state == 'spin':
                    spin_sign = self._last_target_side if self._last_target_side != 0 else 1
                    yaw = spin_sign * SEARCH_SPIN_VELOCITY_DEG_S
                    # Acumular ángulo girado
                    self._search_spin_angle_deg += SEARCH_SPIN_VELOCITY_DEG_S * dt
                    if self._search_spin_angle_deg >= 360.0:
                        # 360° completados → parar, esperar nueva detección
                        yaw = 0
                        self._search_state = 'none'
                        self._search_spin_angle_deg = 0.0

            # ════════════════════════════════════════════════════════════════════
            # ORBIT FSM — sobreescribe lr/fb/ud/yaw calculados por el Follow FSM
            # Solo actúa si _orbit_mode == True
            # ════════════════════════════════════════════════════════════════════
           
            if self._orbit_mode:
                # Resetear los RC calculados por el Follow FSM
                lr = 0; fb = 0; ud = 0; yaw = 0

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
                    # ── SEARCH: esperar a tener target ───────────────────────
                    self._orbit_status = 'searching'
                    self._orbit_ramp = 0.0
                    self.tangential_pid.reset_integral()
                    self.tangential_pid.error_last = 0.0

                    if tracking_target:
                        # Target encontrado → ir a APPROACH
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

                            # Transición a ALIGN cuando estamos suficientemente cerca
                            if orbit_dist_cm <= ORBIT_ALIGN_ENTER_CM:
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

                        if abs(orbit_dist_cm - self._orbit_radius_cm) > ORBIT_ALIGN_EXIT_CM - self._orbit_radius_cm:
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
                                self._orbit_state = 'orbit'
                                self._orbit_ramp = 0.0
                                self.tangential_pid.reset_integral()
                                self.tangential_pid.error_last = 0.0
                                self.yaw_pid.reset_integral()
                                self.pitch_pid.reset_integral()
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

                        # Yaw: feedforward anticipativo + PID correctivo
                        # El FF iguala la rotación esperada al orbitar a velocidad lr
                        error_yaw = self._target_smoothed_x_px - frame_center_x
                        yaw_ff = (self._orbit_sign * ORBIT_YAW_FF_GAIN
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

                        # FB radial: mantener distancia objetivo
                        if orbit_dist_source != 'none':
                            error_dist = self._orbit_radius_cm - orbit_dist_cm

                            # Si nos alejamos demasiado → volver a APPROACH
                            if orbit_dist_cm > ORBIT_MAX_RADIUS_CM:
                                self._orbit_state = 'approach'
                                self._orbit_ramp = 0.0
                                self.pitch_pid.reset_integral()

                            if self._pitch_source_last != 'tof_orbit':
                                self.pitch_pid.error_last = error_dist
                            fb = self.pitch_pid.compute(error_dist, dt)
                        else:
                            fb = 0
                            self.pitch_pid.reset_integral()

                        # Wall stop específico de Orbit
                        if valid_front_tof and current_tof_cm <= ORBIT_WALL_STOP_CM:
                            fb = min(0, fb)  # Solo permite alejarse, no acercarse
                            lr = 0          # Detener movimiento tangencial también
                            self.pitch_pid.reset_integral()

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

                # ── Wall stop diagonal (freeze) también aplica en Orbit ───────
                if time.time() < self._front_tof_freeze_until and fb > 0:
                    fb = 0
                    self.pitch_pid.reset_integral()

                # ── Límite de altitud también aplica en Orbit ─────────────────
                # (height_cm viene del tello state — ya disponible en el scope)
                # NOTA: height_cm debe existir en scope; si no está disponible
                # en tu _video_loop actual, omitir estas dos guards por ahora
                # y añadirlas cuando se integre la lectura de altitud.

                # ── Debug HUD para Orbit ──────────────────────────────────────
                cv2.putText(frame_bgr,
                    f'ORBIT[{self._orbit_state}] lr:{lr:+d} fb:{int(fb):+d} '
                    f'ud:{int(ud):+d} yaw:{int(yaw):+d}',
                    (10, 95), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 180, 255), 2)
                cv2.putText(frame_bgr,
                    f'dist:{orbit_dist_cm:.0f}cm ({orbit_dist_source}) '
                    f'ramp:{self._orbit_ramp:.2f}',
                    (10, 120), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 180, 255), 2)

            # ── Latch pitch source para siguiente frame ───────────────
            # En orbit, las ramas internas ya actualizan _pitch_source_last
            # a 'tof_orbit'; no sobreescribir con el valor del Follow FSM.
            if not self._orbit_mode:
                self._pitch_source_last = pitch_source

            # ── Escribir RC ──────────────────────────────────────────
            with self._rc_lock:
                self._rc = [int(round(lr)), int(round(fb)),
                            int(round(ud)), int(round(yaw))]

            # ── Frame debug ──────────────────────────────────────────
            if best is not None and tracking_target_raw:
                x1, y1, x2, y2, _ = best
                cv2.rectangle(frame_bgr, (x1, y1), (x2, y2), (250, 150, 0), 2)
                if tracked_shoulder_cy is not None:
                    cx_vis = int((x1 + x2) / 2)
                    cv2.circle(frame_bgr, (cx_vis, int(tracked_shoulder_cy)), 6, (0, 255, 255), -1)
            cv2.circle(frame_bgr, (frame_center_x, target_setpoint_y_px), 8, (0, 255, 0), 2)
            if self._target_ema_initialized:
                cv2.circle(frame_bgr, (int(self._target_smoothed_x_px),
                                    int(self._target_smoothed_y_px)), 5, (255, 0, 255), -1)

            tof_label = (f'ToF:{current_tof_cm:.0f}cm' if pitch_source == 'tof'
                        else f'BBox:{self._closeness_smoothed:.3f}')
            cv2.putText(frame_bgr,
                        f'Y:{int(yaw):+d} T:{int(ud):+d} FB:{int(fb):+d} [{tof_label}] {self._follow_status}',
                        (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (250, 150, 0), 2)
            cv2.putText(frame_bgr,
                        f'miss:{self._tracking_miss_count} tof_inv:{self._tof_invalid_count}',
                        (10, 55), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (100, 200, 255), 2)
            yolo_tick = (frame_count % YOLO_FRAME_STRIDE == 0)
            cv2.putText(frame_bgr, '[YOLO]' if yolo_tick else '[EMA]', (10, 75), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 255, 120), 2)

            with self._frame_lock:
                out = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)
                self._debug_frame = cv2.resize(out, (640, 480), interpolation=cv2.INTER_LINEAR)
                self._debug_frame_ts = time.time()

            # Pacing: limitar a ~30 Hz para evitar wind-up de integrales
            time.sleep(max(0.0, (1.0 / 30.0) - (time.time() - _now_t)))

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

        with self._rc_lock:
            self._rc = [0, 0, 0, 0]
        with self._frame_lock:
            self._debug_frame = None

    def activate_orbit(self, radius_cm: float = ORBIT_RADIUS_CM,
                    clockwise: bool = True) -> None:
        """
        Activa el modo Orbit sobre el FollowController activo.
        Puede llamarse con el controller ya en vuelo (tras Follow activo)
        o en frío (el controller arranca directamente en FSM de Orbit).
        """
        self._orbit_radius_cm = radius_cm
        self._orbit_sign = 1 if clockwise else -1
        self._orbit_mode = True
        self._orbit_ramp = 0.0
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
        print(f'[ORBIT] Activado — radio={radius_cm}cm, '
            f'dir={"CW" if clockwise else "CCW"}')

    def deactivate_orbit(self) -> None:
        """Desactiva el modo Orbit y vuelve al Follow normal."""
        self._orbit_mode = False
        self._orbit_state = 'search'
        self._orbit_ramp = 0.0
        self._orbit_status = 'off'
        self._orbit_tof_display = -1.0
        # Neutralizar RC inmediatamente
        with self._rc_lock:
            self._rc = [0, 0, 0, 0]
        print('[ORBIT] Desactivado — volviendo a Follow')
