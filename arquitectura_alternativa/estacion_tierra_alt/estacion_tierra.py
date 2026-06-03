import paho.mqtt.client as mqtt
import random
import threading
import time
import json
import asyncio
import fractions
import ssl
from datetime import datetime
import cv2
import numpy as np
import yaml
import os
import websockets
from aiortc import RTCPeerConnection, RTCSessionDescription, VideoStreamTrack
from aiortc.sdp import candidate_from_sdp
from av import VideoFrame
import torch

from dronLink.Dron import Dron
from TelloLink.Tello import TelloDron

# evitar spam terminal
import logging
logging.getLogger('djitellopy').setLevel(logging.WARNING)
import warnings
warnings.filterwarnings('ignore', category=FutureWarning, module='torch')

# ============================================================
# CONSTANTES
# ============================================================

BROKER = 'broker.hivemq.com'
PORT_MQTT = 1883
SIGNAL_URL = 'wss://dronseetac.upc.edu:8105/ws'

MY_ID = 'python'
REMOTE_ID = 'browser'

# ============================================================
# CONFIGURACION DINAMICA
# ============================================================

flight_mode = 'ardupilot'  # 'ardupilot' | 'sitl' | 'tello'
camera_index = 1

# ============================================================
# ESTADO GLOBAL
# ============================================================

_monitoring = False
_pc = None
_webrtc_running = False
telemetry_channel = None
_camera_track = None
_pending_mission = None
_pending_actions = []
_follow_mode = False
_orbit_active = False
_orbit_thread = None
_ws = None

# ============================================================
# CALIBRACION CAMARA
# ============================================================
CALIB_FILE = 'calibration_data_px.yaml'
cam_matrix = None
dist_coefs = None
new_cam_mtx = None
roi_crop = None

def load_calibration():
    global cam_matrix, dist_coefs, new_cam_mtx, roi_crop
    if not os.path.exists(CALIB_FILE):
        print(f'[WARN] "{CALIB_FILE}" no encontrado - correccion de lente desactivada.')
        return
    with open(CALIB_FILE) as f:
        data = yaml.safe_load(f)
    cam_matrix = np.array(data['camera_matrix'])
    dist_coefs = np.array(data['distortion_coefficients'])
    h, w = 480, 640
    new_cam_mtx, roi = cv2.getOptimalNewCameraMatrix(
        cam_matrix, dist_coefs, (w, h), 1, (w, h))
    roi_crop = roi
    print(f'[INFO] Calibracion cargada desde "{CALIB_FILE}"')

load_calibration()

# ============================================================
# MODELO YOLO
# ============================================================

DEVICE = 'cuda' if torch.cuda.is_available() else 'cpu'
print(f'[INFO] YOLO usando: {DEVICE}')

model = torch.hub.load('ultralytics/yolov5', 'yolov5s', pretrained=True)
model.eval()
if DEVICE == 'cuda':
    model = model.cuda()

# modelo yolo para tello (detecta poses)
from ultralytics import YOLO
pose_model = YOLO('yolov8n-pose.onnx')

# ============================================================
# LOOP ASYNCIO
# ============================================================

loop = asyncio.new_event_loop()

def _start_loop(lp):
    asyncio.set_event_loop(lp)
    lp.run_forever()

threading.Thread(target=_start_loop, args=(loop,), daemon=True).start()

# ============================================================
# PID CONTROLLER  (equivalente a pid_controller.py del proyecto referencia)
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
        self.integral_error = max(self.output_min, min(self.output_max, self.integral_error))
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
GAINS_YAW_PID         = (0.3,  0.002,  0.1)   # kp, ki, kd
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
FRAME_W = 960
FRAME_H = 720
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
YOLO_FRAME_STRIDE   = 25
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
# ORBIT CONTROLLER 
# ============================================================

# Radio objetivo de órbita
ORBIT_RADIUS_CM              = 100.0   # distancia deseada persona-drone
ORBIT_ALIGN_ENTER_CM         = 115.0   # ToF para transición APPROACH → ALIGN
ORBIT_ALIGN_EXIT_CM          = 135.0   # ToF para transición ALIGN → APPROACH
ORBIT_STABLE_TOF_MARGIN_CM   = 8.0     # tolerancia ToF en ALIGN para considerar estable
ORBIT_ALIGN_PX_THRESH        = 30      # píxeles máximos de error yaw en ALIGN
ORBIT_ALIGN_STABLE_FRAMES    = 12      # frames consecutivos estables para entrar en ORBIT
ORBIT_ALIGN_TIMEOUT_S        = 8.0     # timeout máximo en ALIGN antes de reintentar

ORBIT_TANGENTIAL_SPEED       = 18      # lr feedforward base [RC units, 0–100]
ORBIT_LR_MAX_VELOCITY        = 35      # límite lr (feedforward + PID)
ORBIT_RAMP_STEP              = 0.04    # rampa: ~25 ciclos (1.25s) para máximo lr
ORBIT_MAX_RADIUS_CM          = 170.0   # ToF máximo en ORBIT → transición a APPROACH
ORBIT_LOST_FRAMES            = 6       # frames consecutivos sin target → estado 'lost'
ORBIT_LOST_GRACE_S           = 3.0     # gracia en 'lost' antes de 'search'
ORBIT_WALL_STOP_CM           = 35.0    # wall stop específico de Orbit (más conservador)

# Closeness setpoint para Orbit (bbox fallback cuando no hay ToF)
# Radio 100cm ≈ bbox_height_ratio ~0.55 en Tello con persona adulta
ORBIT_CLOSENESS_SETPOINT = 0.55


class FollowController:
    """
    Modo Follow.
    FSM: INTERCEPTING → HOVER (grace) → SEARCHING (spin 360°)
    Pitch dual: ToF (prioritario) / bbox_ratio (fallback).
    Arquitectura de hilos conservada (vid_thread, rc_thread, tof_thread).
    """

    def __init__(self, tello_ref):
        self._tello = tello_ref
        self._active = True

        # ── SDK lock 
        self._sdk_lock = threading.Lock()

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
                    raw = self._tello._tello.send_command_with_return('EXT tof?', timeout=1)
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

    # ------------------------------------------------------------------ RC loop
    def _rc_loop(self):
        while self._active:
            t0 = time.time()
            with self._rc_lock:
                lr, fb, ud, yaw = self._rc
            try:
                with self._sdk_lock:
                    self._tello.rc(lr, fb, ud, yaw)
            except Exception as e:
                print(f'[FOLLOW] rc error: {e}')
            elapsed = time.time() - t0
            time.sleep(max(0.0, RC_LOOP_INTERVAL_S - elapsed))

    # ------------------------------------------------------------------ Detección YOLO
    def _detect_persons(self, frame_rgb):
        """Retorna lista de (x1,y1,x2,y2, shoulder_cy_or_None)."""
        results = pose_model(frame_rgb, imgsz=320, verbose=False)
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
                x2 = min(int(box[2]), FRAME_W)
                y2 = min(int(box[3]), FRAME_H)
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
        frame_count        = 0
        consecutive_none   = 0
        detected_persons   = []

        while self._active:
            frame_rgb = self._tello.get_frame()

            if frame_rgb is None:
                consecutive_none += 1
                if consecutive_none > 300:
                    print('[FOLLOW] Stream muerto, deteniendo.')
                    self._active = False
                    break
                time.sleep(0.01)
                continue
            consecutive_none = 0

            frame_count += 1
            frame_bgr = cv2.cvtColor(frame_rgb, cv2.COLOR_RGB2BGR)
            actual_h, actual_w = frame_bgr.shape[:2]

            # Setpoint vertical: hombros al 25% superior del frame
            target_setpoint_y_px = int(actual_h * TARGET_Y_RATIO)

            # ── Detección YOLO (cada STRIDE frames) ─────────────────
            if frame_count % YOLO_FRAME_STRIDE == 0:
                detected_persons = self._detect_persons(frame_rgb)

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
            if tracking_target:
                if tracking_target_raw:
                    self._last_target_seen_time = now
                    # Actualizar lado del target (para recovery yaw)
                    side = target_x_px - FRAME_CENTER_X
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
                ud = self.altitude_pid.compute(error_altitude, RC_LOOP_INTERVAL_S)

                # ── Yaw PID ──────────────────────────────────────────
                error_yaw = self._target_smoothed_x_px - FRAME_CENTER_X
                yaw = self.yaw_pid.compute(error_yaw, RC_LOOP_INTERVAL_S)

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
                    fb = self.pitch_pid.compute(error_pitch, RC_LOOP_INTERVAL_S)
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
                    fb = self.pitch_bbox_pid.compute(error_pitch, RC_LOOP_INTERVAL_S)
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
            elif (self._last_target_seen_time > 0 and
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
            else:
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
                    self._search_spin_angle_deg += SEARCH_SPIN_VELOCITY_DEG_S * RC_LOOP_INTERVAL_S
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
                ud = self.altitude_pid.compute(error_altitude, RC_LOOP_INTERVAL_S)
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
                    # Mantener último RC hasta confirmar pérdida
                else:
                    self._orbit_lost_count = 0

                if tracking_target:
                    # Yaw: centrar la persona
                    error_yaw = self._target_smoothed_x_px - FRAME_CENTER_X
                    yaw = self.yaw_pid.compute(error_yaw, RC_LOOP_INTERVAL_S)

                    if orbit_dist_source != 'none':
                        error_pitch = self._orbit_radius_cm - orbit_dist_cm
                        if self._pitch_source_last != 'tof_orbit':
                            self.pitch_pid.error_last = error_pitch
                        fb = self.pitch_pid.compute(error_pitch, RC_LOOP_INTERVAL_S)

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
                    error_yaw = self._target_smoothed_x_px - FRAME_CENTER_X
                    error_dist = self._orbit_radius_cm - orbit_dist_cm

                    yaw = self.yaw_pid.compute(error_yaw, RC_LOOP_INTERVAL_S)

                    if abs(orbit_dist_cm - self._orbit_radius_cm) > ORBIT_ALIGN_EXIT_CM - self._orbit_radius_cm:
                        fb = self.pitch_pid.compute(error_dist, RC_LOOP_INTERVAL_S)
                    else:
                        fb = 0
                        self.pitch_pid.reset_integral()

                    lr = 0

                    # Condición de estabilidad para entrar en ORBIT
                    yaw_stable = abs(error_yaw) < ORBIT_ALIGN_PX_THRESH
                    dist_stable = abs(error_dist) < ORBIT_STABLE_TOF_MARGIN_CM
                    if yaw_stable and dist_stable:
                        if not hasattr(self, '_orbit_align_stable_count'):
                            self._orbit_align_stable_count = 0
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

                    # Yaw: mantener persona centrada
                    error_yaw = self._target_smoothed_x_px - FRAME_CENTER_X
                    yaw = self.yaw_pid.compute(error_yaw, RC_LOOP_INTERVAL_S)

                    # LR tangencial: feedforward * rampa + corrección PID centrado
                    # El PID tangencial corrige el error de centrado horizontal
                    # para mantener la persona en el centro mientras orbita
                    tangential_correction = self.tangential_pid.compute(
                        error_yaw, RC_LOOP_INTERVAL_S)
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
                        fb = self.pitch_pid.compute(error_dist, RC_LOOP_INTERVAL_S)
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
            cv2.circle(frame_bgr, (FRAME_CENTER_X, target_setpoint_y_px), 8, (0, 255, 0), 2)
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

    # ------------------------------------------------------------------ API pública
    def get_debug_frame(self):
        with self._frame_lock:
            return self._debug_frame

    def stop(self):
        self._active = False
        time.sleep(0.6)
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


_follow_ctrl: FollowController = None

# ============================================================
# ORBIT
# ============================================================

def run_orbit(radius_cm: int, clockwise: bool):
    global _orbit_active
    print(f"[ORBIT] Iniciando — tello={tello}, state={tello.state if tello else 'None'}")
    yaw_speed = 30
    fwd_speed = max(10, min(50, int(radius_cm * 0.15)))
    if not clockwise:
        yaw_speed = -yaw_speed
    try:
        interval = 1.0 / 20.0
        while _orbit_active:
            print(f"[ORBIT] tick state={tello.state}")
            if tello is None or tello.state != 'flying':
                print(f"[ORBIT] Saliendo — state={tello.state}")
                break
            t0 = time.time()
            tello.rc(0, fwd_speed, 0, yaw_speed)
            elapsed = time.time() - t0
            time.sleep(max(0.0, interval - elapsed))
    finally:
        _orbit_active = False
        try:
            if tello:
                tello.rc(0, 0, 0, 0)
        except Exception:
            pass

# ============================================================
# MQTT callbacks
# ============================================================

def on_connect(client, userdata, flags_dict, rc):
    if rc == 0:
        print('Ground Station conectada :)')
        client.subscribe('mobileFlutter/groundStation/#')
        print('Esperando comandos...')
    else:
        print(f'Error conectando al broker, codigo: {rc}')

def process_telemetry_info(telemetry_info):
    global telemetry_channel
    payload = json.dumps(telemetry_info)
    if telemetry_channel is not None and telemetry_channel.readyState == 'open':
        try:
            loop.call_soon_threadsafe(telemetry_channel.send, payload)
        except Exception as e:
            print(f'Error enviando telemetría: {e}')

def process_tello_telemetry():
    global telemetry_channel
    while flight_mode == 'tello' and tello is not None and tello.state != 'disconnected':
        try:
            vx = getattr(tello, 'vx_cm_s', 0) or 0
            vy = getattr(tello, 'vy_cm_s', 0) or 0
            payload = json.dumps({
                'lat': 0.0,
                'lon': 0.0,
                'alt': (getattr(tello, 'height_cm', 0) or 0) / 100.0,
                'groundSpeed': (vx**2 + vy**2)**0.5 / 100.0,
                'battery_remaining': getattr(tello, 'battery_pct', 0) or 0,
                'heading': getattr(tello, 'yaw_deg', 0) or 0,
                'vx': vx / 100.0,
                'vy': vy / 100.0,
                'state': tello.state,
                'flightMode': 'TELLO',
                'followStatus': _follow_ctrl._follow_status if (_follow_ctrl and _follow_mode) else 'off',
                'tofDistance': _follow_ctrl._tof_display if (_follow_ctrl and _follow_mode) else -1.0,
                'orbitStatus': _follow_ctrl._orbit_status if (_follow_ctrl and _follow_ctrl._orbit_mode) else 'off',
                'orbitTofDistance': _follow_ctrl._orbit_tof_display if (_follow_ctrl and _follow_ctrl._orbit_mode) else -1.0,
            })
            if telemetry_channel is not None and telemetry_channel.readyState == 'open':
                loop.call_soon_threadsafe(telemetry_channel.send, payload)
        except Exception as e:
            print("error")
        time.sleep(0.2)

def monitor_arm_state():
    global _monitoring
    if _monitoring:
        return
    _monitoring = True
    time.sleep(1)
    for _ in range(300):
        if dron.vehicle is None:
            break
        if not dron.vehicle.motors_armed():
            client.publish('groundStation/mobileFlutter/disarmed', 'disarmed')
            break
        time.sleep(1)
    _monitoring = False

def handle_joystick(data_str):
    global _orbit_active
    try:
        data = json.loads(data_str)
        lx = data.get('lx', 0.0)
        ly = data.get('ly', 0.0)
        rx = data.get('rx', 0.0)
        ry = data.get('ry', 0.0)

        if flight_mode == 'tello':
            if tello is None: return
            if _follow_mode: return
            if _orbit_active: return
            if tello.state != 'flying': return
            threshold = 0.1
            def to_rc(v): return int(v * 100)
            tello.rc(
                to_rc(rx) if abs(rx) >= threshold else 0,
                to_rc(ry) if abs(ry) >= threshold else 0,
                to_rc(ly) if abs(ly) >= threshold else 0,
                to_rc(lx) if abs(lx) >= threshold else 0,
            )
            return

        if dron.state not in ('flying', 'returning'):
            return
        threshold = 0.1
        def to_pwm(v): return int(1500 + v * 500)
        dron.send_rc(
            to_pwm(rx) if abs(rx) >= threshold else 1500,
            to_pwm(ry) if abs(ry) >= threshold else 1500,
            to_pwm(ly) if abs(ly) >= threshold else 1500,
            to_pwm(lx) if abs(lx) >= threshold else 1500,
        )
    except Exception as e:
        print('Error joystick')


# --------------------- HANDLER DE MENSAJES MQTT ---------------------

def on_message(client, userdata, message):
    global _pc, _camera_track, flight_mode, camera_index, _follow_mode, tello, _follow_ctrl
    global _orbit_active, _orbit_thread

    parts = message.topic.split('/')
    command = parts[2] if len(parts) > 2 else "PARTS ERROR"
    print(f'Comando recibido: {command}, payload = {message.payload.decode()}')


    # ------------------ MODOS -----------------
    if command == 'setMode':
        mode = message.payload.decode().strip()
        if mode in ('ardupilot', 'sitl', 'tello'):
            flight_mode = mode
            if mode == 'tello' and tello is None:
                tello = TelloDron()
            print(f'[CONFIG] Modo de vuelo: {flight_mode}')
        else:
            print(f'[WARN] Modo desconocido: {mode}')

    # ------------------ CAMARA -----------------
    if command == 'setCamera':
        try:
            idx = int(message.payload.decode().strip())
            if idx in (0, 1):
                camera_index = idx
                print(f'[CONFIG] Camara: {camera_index}')
                if _camera_track is not None:
                    _camera_track.set_camera(camera_index)
            else:
                print(f'[WARN] Indice de camara no valido: {idx}')
        except ValueError:
            print('[WARN] setCamera: valor no numerico')

    # ------------------ CONECTAR -----------------
    if command == 'connect':
        def conectar():
            global _pc, _camera_track, telemetry_channel
            if flight_mode == 'tello':
                already_connected = tello.state in ('connected', 'flying')
                if not already_connected:
                    print('[TELLO] Conectando...')
                    ok = tello.connect(blocking=True)
                    if not ok or tello.state == 'disconnected':
                        print('[TELLO] Error al conectar')
                        client.publish('groundStation/mobileFlutter/disconnected', 'connection_failed')
                        return
                    tello.startTelemetry(freq_hz=5)
                    threading.Thread(target=process_tello_telemetry, daemon=True).start()
                else:
                    print(f'[TELLO] Recuperacion de sesion - estado: "{tello.state}"')
                if _pc is not None:
                    fut = asyncio.run_coroutine_threadsafe(_pc.close(), loop)
                    fut.result(timeout=3)
                    _pc = None; _camera_track = None; telemetry_channel = None
                client.publish('groundStation/mobileFlutter/connected', 'connected')
                time.sleep(0.3)
                if tello.state == 'flying':
                    client.publish('groundStation/mobileFlutter/flying', 'flying')
                asyncio.run_coroutine_threadsafe(webrtc_client(), loop)
                return

            conn_str = 'com7' if flight_mode == 'ardupilot' else 'tcp:127.0.0.1:5763'
            baud = 57600 if flight_mode == 'ardupilot' else 115200
            already = dron.state in ('connected', 'armed', 'flying', 'returning')
            if already and hasattr(dron, '_conn_str') and dron._conn_str != conn_str:
                already = False
                try: dron.stop_sending_telemetry_info(); dron.disconnect()
                except Exception: pass
            if not already:
                try:
                    dron.connect(conn_str, baud); dron._conn_str = conn_str
                    if dron.vehicle is None: raise Exception('Vehicle is None')
                    dron.frequency = 2
                    dron.send_telemetry_info(process_telemetry_info)
                except Exception as e:
                    print(f'Error al conectar: {e}')
                    client.publish('groundStation/mobileFlutter/disconnected', 'connection_failed')
                    return
            else:
                if _ws is not None:
                    try:
                        fut = asyncio.run_coroutine_threadsafe(_ws.close(), loop)
                        fut.result(timeout=5)
                    except Exception: pass

            if _pc is not None:
                try: asyncio.run_coroutine_threadsafe(_pc.close(), loop)
                except Exception: pass
                _pc = None; _camera_track = None; telemetry_channel = None
            try: dron.stop_sending_telemetry_info()
            except Exception: pass
            dron.send_telemetry_info(process_telemetry_info)
            client.publish('groundStation/mobileFlutter/connected', 'connected')
            time.sleep(0.3)
            if dron.state in ('armed', 'flying', 'returning'):
                client.publish('groundStation/mobileFlutter/armed', 'armed')
            if dron.state in ('flying', 'returning'):
                time.sleep(0.1)
                client.publish('groundStation/mobileFlutter/flying', 'flying')
            asyncio.run_coroutine_threadsafe(webrtc_client(), loop)
        threading.Thread(target=conectar).start()

    # ------------------ ARMAR -----------------
    if command == 'arm':
        if flight_mode == 'tello': return
        if dron.state == 'connected':
            def armar():
                dron.arm()
                client.publish('groundStation/mobileFlutter/armed', 'armed')
                threading.Thread(target=monitor_arm_state, daemon=True).start()
            threading.Thread(target=armar).start()

    # ------------------ DESPEGAR -----------------
    if command == 'takeoff':
        if flight_mode == 'tello':
            if tello is None: return
            if tello.state == 'connected':
                def despegar_tello():
                    tello.takeOff(blocking=True)
                    client.publish('groundStation/mobileFlutter/flying', 'flying')
                threading.Thread(target=despegar_tello, daemon=True).start()
            return
        if dron.state in ('armed', 'flying'):
            parts_p = message.payload.decode().split(':')
            altitude = int(parts_p[0])
            speed = float(parts_p[1]) if len(parts_p) > 1 else dron.navSpeed
            def despegar():
                dron.navSpeed = speed; dron.takeOff(altitude)
                dron.vehicle.set_mode('LOITER'); dron.changeNavSpeed(speed)
                client.publish('groundStation/mobileFlutter/flying', 'flying')
            threading.Thread(target=despegar).start()

    # ------------------ ATERRIZAR -----------------
    if command == 'land':
        if flight_mode == 'tello':
            if tello is None: return
            if tello.state == 'flying':
                if _follow_mode:
                    _follow_mode = False
                    if _follow_ctrl: _follow_ctrl.stop()
                def aterrizar_tello():
                    tello.Land(blocking=True)
                    client.publish('groundStation/mobileFlutter/landed', 'landed')
                threading.Thread(target=aterrizar_tello, daemon=True).start()
            return
        if dron.state in ('flying', 'returning'):
            def aterrizar():
                dron.Land()
                client.publish('groundStation/mobileFlutter/landed', 'landed')
            threading.Thread(target=aterrizar).start()

    # ------------------ RETURN TO LAUNCH -----------------
    if command == 'rtl':
        if flight_mode == 'tello': return
        if dron.state in ('flying', 'returning'):
            def rtl():
                dron.changeNavSpeed(dron.navSpeed); dron.RTL()
                client.publish('groundStation/mobileFlutter/landed', 'landed')
            threading.Thread(target=rtl).start()

    # ------------------ VELOCIDAD DE NAVEGACION -----------------
    if command == 'speed':
        if flight_mode == 'tello': return
        spd = float(message.payload.decode())
        dron.navSpeed = spd
        if dron.vehicle: dron.changeNavSpeed(spd)

    # ------------------ ZOOM -----------------
    if command == 'zoom':
        try:
            zoom_val = max(1.0, min(float(message.payload.decode()), 10.0))
            if _camera_track: _camera_track.zoom_factor = zoom_val
        except ValueError:
            print('[WARN] Zoom: valor invalido')

    # ------------------ FLIP -----------------
    if command == 'flip':
        if flight_mode == 'tello' and tello and tello.state == 'flying':
            d = message.payload.decode().strip()
            if _follow_ctrl is not None:
                with _follow_ctrl._sdk_lock:
                    try: tello._tello.flip(d[0])
                    except Exception as e: print(f'[TELLO] Flip error: {e}')
            else:
                try: tello._tello.flip(d[0])
                except Exception as e: print(f'[TELLO] Flip error: {e}')

    # ------------------ MODO ORBITA TELLO -----------------
    if command == 'orbit':
        if flight_mode == 'tello' and tello and tello.state == 'flying':
            payload_str = message.payload.decode().strip()

            # Si se recibe "stop", desactivar modo Orbit
            if payload_str == 'stop':
                print('[ORBIT] STOP recibido')
                if _follow_ctrl is not None and _follow_ctrl._orbit_mode:
                    _follow_ctrl.deactivate_orbit()
                # Compatibilidad con _orbit_active legacy (guard de joystick)
                _orbit_active = False
                if _orbit_thread and _orbit_thread.is_alive():
                    _orbit_thread.join(timeout=0.3)

            else:
                # Parsear parámetros: "100:cw" 
                try:
                    parts_o = payload_str.split(':')
                    radius_cm = float(parts_o[0])
                    clockwise = len(parts_o) < 2 or parts_o[1].lower() != 'ccw'
                except (ValueError, IndexError):
                    radius_cm = ORBIT_RADIUS_CM
                    clockwise = True

                # Detener Follow si estaba activo y reusar su controlador
                if _follow_mode:
                    print('[ORBIT] Follow activo — reutilizando FollowController')
                    # No llamamos _follow_ctrl.stop() — conservamos los hilos
                    _follow_mode = False

                # Si no hay controlador, crearlo y arrancar hilos
                if _follow_ctrl is None:
                    _follow_ctrl = FollowController(tello)
                else:
                    # Reusar instancia existente — rearrancar hilos si están muertos
                    _follow_ctrl._tello = tello
                    _follow_ctrl._active = True
                    if not _follow_ctrl._rc_thread.is_alive():
                        _follow_ctrl._rc_thread = threading.Thread(
                            target=_follow_ctrl._rc_loop, daemon=True)
                        _follow_ctrl._rc_thread.start()
                    if not _follow_ctrl._vid_thread.is_alive():
                        _follow_ctrl._vid_thread = threading.Thread(
                            target=_follow_ctrl._video_loop, daemon=True)
                        _follow_ctrl._vid_thread.start()
                    if not _follow_ctrl._tof_thread.is_alive():
                        _follow_ctrl._tof_thread = threading.Thread(
                            target=_follow_ctrl._tof_loop, daemon=True)
                        _follow_ctrl._tof_thread.start()

                # Activar modo Orbit sobre el controlador
                _follow_ctrl.activate_orbit(radius_cm=radius_cm,
                                            clockwise=clockwise)
                # Marcar como orbit activo (guard de joystick)
                _orbit_active = True
                print(f'[ORBIT] Lanzado — radius={radius_cm}cm, '
                      f'cw={clockwise}')
                

    # ------------------ MODO FOLLOW TELLO -----------------
    if command == 'followMode':
        if flight_mode == 'tello' and tello and tello.state == 'flying':
            new_state = message.payload.decode().strip() == 'true'
            if new_state == _follow_mode:
                return
            _follow_mode = new_state
            if _follow_mode:
                if _orbit_active:
                    _orbit_active = False
                    if _orbit_thread and _orbit_thread.is_alive():
                        _orbit_thread.join(timeout=0.5)
                if _follow_ctrl is None:
                    _follow_ctrl = FollowController(tello)
                else:
                    _follow_ctrl._tello = tello
                    _follow_ctrl._active = True
                    _follow_ctrl.reset_pids()
                    if not _follow_ctrl._rc_thread.is_alive():
                        _follow_ctrl._rc_thread = threading.Thread(
                            target=_follow_ctrl._rc_loop, daemon=True)
                        _follow_ctrl._rc_thread.start()
                    if not _follow_ctrl._vid_thread.is_alive():
                        _follow_ctrl._vid_thread = threading.Thread(
                            target=_follow_ctrl._video_loop, daemon=True)
                        _follow_ctrl._vid_thread.start()
                    if not _follow_ctrl._tof_thread.is_alive():
                        _follow_ctrl._tof_thread = threading.Thread(
                            target=_follow_ctrl._tof_loop, daemon=True)
                        _follow_ctrl._tof_thread.start()
                print('[TELLO] Follow mode ACTIVADO')
            else:
                if _follow_ctrl: _follow_ctrl.stop()
                print('[TELLO] Follow mode DESACTIVADO')

    if command == 'detectionMode':
        mode = message.payload.decode()
        if _camera_track:
            _camera_track.detection_mode = mode
            _camera_track.detecciones = []

    if command == 'disconnect':
        if flight_mode == 'tello':
            if tello is None: return
            def desconectar_tello():
                global _pc, _camera_track, _follow_mode, _follow_ctrl
                _follow_mode = False
                if _follow_ctrl: _follow_ctrl.stop(); _follow_ctrl = None
                try: tello.stream_off()
                except Exception: pass
                try: tello.disconnect()
                except Exception as e:
                    print("error al desconectar")
                if _pc:
                    try: asyncio.run_coroutine_threadsafe(_pc.close(), loop)
                    except Exception: pass
                    _pc = None; _camera_track = None
                client.publish('groundStation/mobileFlutter/disconnected', 'disconnected')
            threading.Thread(target=desconectar_tello, daemon=True).start()
            return
        def desconectar():
            global _pc, _camera_track, _ws
            try: dron.stop_sending_telemetry_info()
            except Exception: pass
            client.publish('groundStation/mobileFlutter/disconnected', 'disconnected')
            dron.disconnect()
            if _ws is not None:
                try:
                    fut = asyncio.run_coroutine_threadsafe(_ws.close(), loop)
                    fut.result(timeout=5)
                except Exception: pass
            if _pc:
                try: asyncio.run_coroutine_threadsafe(_pc.close(), loop)
                except Exception as e: print(f'Error cerrando PC: {e}')
            _pc = None; _camera_track = None
        threading.Thread(target=desconectar).start()

    if command == 'uploadMission':
        global _pending_mission, _pending_actions
        try:
            data = json.loads(message.payload.decode())
            wp_data = data.get('waypoints', [])
            takeoff_alt = data.get('takeoffAlt', 5)
            speed = data.get('speed', dron.navSpeed)
            dronlink_wp = []
            actions = []
            for wp in wp_data:
                dronlink_wp.append({'lat': float(wp['lat']),
                                    'lon': float(wp['lon']),
                                    'alt': float(wp['altM'])})
                actions.append(wp.get('action', {'type': 'none', 'seconds': 5}))
            _pending_mission = {'speed': speed, 'takeOffAlt': takeoff_alt,
                                'waypoints': dronlink_wp}
            _pending_actions = actions
            client.publish('groundStation/mobileFlutter/missionUploaded', 'ok')
        except Exception as e:
            client.publish('groundStation/mobileFlutter/missionUploaded', f'error:{e}')

    if command == 'startMission':
        if _pending_mission is None:
            client.publish('groundStation/mobileFlutter/missionStarted', 'error')
            return
        def run_mission():
            client.publish('groundStation/mobileFlutter/missionStarted', 'ok')
            try:
                if not dron.vehicle.motors_armed():
                    dron.arm()
                    client.publish('groundStation/mobileFlutter/armed', 'armed')
                dron.takeOff(_pending_mission['takeOffAlt'])
                dron.changeNavSpeed(_pending_mission['speed'])
                client.publish('groundStation/mobileFlutter/flying', 'flying')
                for index, wp in enumerate(_pending_mission['waypoints']):
                    client.publish('groundStation/mobileFlutter/missionWaypoint', str(index))
                    dron.goto(float(wp['lat']), float(wp['lon']), float(wp['alt']))
                    if index < len(_pending_actions):
                        action = _pending_actions[index]
                        action_type = action.get('type', 'none')
                        action_secs = float(action.get('seconds', 5))
                        if action_type == 'hover':
                            time.sleep(action_secs)
                        elif action_type == 'takePhoto':
                            client.publish('groundStation/mobileFlutter/cameraAction', 'photo')
                        elif action_type == 'recordVideo':
                            client.publish('groundStation/mobileFlutter/cameraAction',
                                           f'record:{int(action_secs)}')
                            time.sleep(action_secs)
                        elif action_type in ('rtl', 'land'):
                            dron.RTL() if action_type == 'rtl' else dron.Land()
                            client.publish('groundStation/mobileFlutter/landed', 'landed')
                            return
                dron.RTL()
                client.publish('groundStation/mobileFlutter/landed', 'landed')
            except Exception as e:
                print(f'[MISSION ERROR] {e}')
                client.publish('groundStation/mobileFlutter/landed', 'landed')
        threading.Thread(target=run_mission, daemon=True).start()

# ============================================================
# WEBRTC - Video Track
# ============================================================

class CameraVideoTrack(VideoStreamTrack):
    def __init__(self, cam_idx=1):
        super().__init__()
        self.zoom_factor = 1.0
        self.detection_mode = 'all'
        self.detecciones = []
        self.frame_count = 0
        self.correct_lens = cam_matrix is not None
        self.cap = None

        if flight_mode == 'tello':
            tello.stream_on()
            time.sleep(1.0)
            print(f"Stream Tello: {'OK' if tello.get_frame() is not None else 'None'}")
        else:
            self.set_camera(cam_idx)

    def set_camera(self, idx):
        if self.cap is not None:
            self.cap.release()
        print(f'[CAM] Abriendo camara {idx}...')
        self.cap = cv2.VideoCapture(idx)
        if not self.cap.isOpened():
            print(f'[ERROR] No se pudo abrir la camara {idx}')

    def _undistort(self, frame):
        if not self.correct_lens:
            return frame
        u = cv2.undistort(frame, cam_matrix, dist_coefs, None, new_cam_mtx)
        x, y, w, h = roi_crop
        if w > 0 and h > 0:
            u = u[y:y+h, x:x+w]
        return u

    def _apply_zoom(self, frame):
        if self.zoom_factor <= 1.0:
            return frame
        fh, fw = frame.shape[:2]
        sx, sy = int(fw / self.zoom_factor), int(fh / self.zoom_factor)
        cx, cy = fw // 2, fh // 2
        cropped = frame[max(0, cy-sy//2):min(fh, cy+sy//2),
                        max(0, cx-sx//2):min(fw, cx+sx//2)]
        return cv2.resize(cropped, (fw, fh), interpolation=cv2.INTER_LINEAR)

    async def recv(self):
        self.frame_count += 1

        if flight_mode == 'tello':
            frame = tello.get_frame()
            if frame is None:
                frame = np.zeros((480, 640, 3), dtype=np.uint8)
        else:
            ret, frame = self.cap.read()
            if not ret:
                frame = np.zeros((480, 640, 3), dtype=np.uint8)
            frame = self._undistort(frame)
            frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)

        frame = self._apply_zoom(frame)
        frame = cv2.resize(frame, (640, 480), interpolation=cv2.INTER_LINEAR)

        if flight_mode == 'tello':
            ctrl_active = ((_follow_mode or _orbit_active) and _follow_ctrl is not None and tello.state == 'flying')
            if ctrl_active:
                debug = _follow_ctrl.get_debug_frame()
                if debug is not None:
                    frame = debug
            vf = VideoFrame.from_ndarray(frame, format='rgb24')
            vf.pts, vf.time_base = self.frame_count, fractions.Fraction(1, 30)
            return vf

        if self.frame_count % 25 == 0 and self.detection_mode != 'none':
            results = model(frame)
            self.detecciones = []
            for *box, conf, cls in results.xyxy[0]:
                x1, y1, x2, y2 = map(int, box)
                label = model.names[int(cls.item())]
                confidence = float(conf.item())
                if self.detection_mode == 'person' and label != 'person':
                    continue
                self.detecciones.append((x1, y1, x2, y2, label, confidence))

        if self.detection_mode == 'none':
            self.detecciones = []

        frame_bgr = cv2.cvtColor(frame, cv2.COLOR_RGB2BGR)
        color = (0, 255, 0) if self.detection_mode == 'all' else (0, 150, 255)
        for (x1, y1, x2, y2, label, confidence) in self.detecciones:
            cv2.rectangle(frame_bgr, (x1,y1), (x2,y2), color, 2)
            cv2.putText(frame_bgr, f'{label} ({confidence*100:.0f}%)',
                        (x1, y1-10), cv2.FONT_HERSHEY_SIMPLEX, 0.6, color, 2)
        ts = datetime.now().strftime('%H:%M:%S.%f')[:-3]
        cv2.putText(frame_bgr, ts, (10,30), cv2.FONT_HERSHEY_SIMPLEX, 1, (0,255,0), 2)
        frame = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)
        vf = VideoFrame.from_ndarray(frame, format='rgb24')
        vf.pts, vf.time_base = self.frame_count, fractions.Fraction(1, 30)
        return vf

# ============================================================
# WEBRTC - señalización
# ============================================================

async def webrtc_client():
    global _pc, telemetry_channel, _camera_track, _webrtc_running, _ws

    if _webrtc_running:
        print('[WEBRTC] Ya hay una sesion activa, ignorando.')
        return
    _webrtc_running = True

    if _pc is not None:
        try: await _pc.close()
        except Exception: pass
        _pc = None

    ssl_ctx = ssl.create_default_context()
    ssl_ctx.check_hostname = False
    ssl_ctx.verify_mode = ssl.CERT_NONE

    try:
        async with websockets.connect(SIGNAL_URL, ssl=ssl_ctx) as ws:
            _ws = ws
            await ws.send(MY_ID)
            await ws.send(json.dumps({
                'target': REMOTE_ID, 'type': 'ice_config',
                'iceServers': [
                    {'urls': 'stun:stun.l.google.com:19302'},
                    {'urls': 'stun:stun1.l.google.com:19302'},
                ],
            }))
            await asyncio.sleep(0.8)

            _pc = RTCPeerConnection()
            joystick_channel = _pc.createDataChannel('joystick')
            telemetry_channel = _pc.createDataChannel('telemetry')

            @joystick_channel.on('message')
            def on_joystick(msg): handle_joystick(msg)

            @_pc.on('icecandidate')
            async def on_ice(candidate):
                payload = {
                    'target': REMOTE_ID, 'type': 'candidate',
                    'candidate': {
                        'candidate': candidate.candidate,
                        'sdpMid': candidate.sdpMid,
                        'sdpMLineIndex': candidate.sdpMLineIndex,
                    } if candidate else None
                }
                await ws.send(json.dumps(payload))

            track = CameraVideoTrack(cam_idx=camera_index)
            _camera_track = track
            _pc.addTrack(track)

            offer = await _pc.createOffer()
            await _pc.setLocalDescription(offer)
            await ws.send(json.dumps({
                'target': REMOTE_ID, 'type': 'offer',
                'offer': {'sdp': _pc.localDescription.sdp,
                          'type': _pc.localDescription.type},
            }))
            print('Offer enviada, esperando answer...')

            async for raw in ws:
                data = json.loads(raw)
                if data.get('type') == 'answer':
                    await _pc.setRemoteDescription(RTCSessionDescription(
                        sdp=data['answer']['sdp'], type=data['answer']['type']))
                    print('WebRTC handshake completo')
                if data.get('type') == 'candidate':
                    cand = data.get('candidate')
                    if not cand: continue
                    try:
                        rc = candidate_from_sdp(cand['candidate'])
                        rc.sdpMid = cand.get('sdpMid') or '0'
                        rc.sdpMLineIndex = cand.get('sdpMLineIndex') or 0
                        await _pc.addIceCandidate(rc)
                    except Exception as e:
                        print(f'Error ICE candidate: {e}')
    except Exception as e:
        print(f'Error en webrtc_client: {e}')
    finally:
        _ws = None
        _webrtc_running = False
        _pc = None
        telemetry_channel = None
        _camera_track = None

# ============================================================
# ARRANQUE
# ============================================================

dron = Dron()
dron.navSpeed = 3.0
dron._conn_str = None

tello = TelloDron()

client_name = 'groundStation' + str(random.randint(1000, 9000))
client = mqtt.Client(client_name)
client.on_connect = on_connect
client.on_message = on_message

print(f'Conectando al broker {BROKER}:{PORT_MQTT}...')
client.connect(BROKER, PORT_MQTT)
client.loop_start()

print('Sistema listo. Esperando comandos MQTT...')
threading.Event().wait()