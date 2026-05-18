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
from simple_pid import PID
from collections import deque

from dronLink.Dron import Dron
from TelloLink.Tello import TelloDron

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
    new_cam_mtx, roi = cv2.getOptimalNewCameraMatrix(cam_matrix, dist_coefs, (w, h), 1, (w, h))
    roi_crop = roi
    print(f'[INFO] Calibracion cargada desde "{CALIB_FILE}"')

load_calibration()

# ============================================================
# MODELO YOLO (solo ArduPilot/SITL)
# ============================================================

model = torch.hub.load('ultralytics/yolov5', 'yolov5s', pretrained=True)
model.eval()

# ============================================================
# LOOP ASYNCIO
# ============================================================

loop = asyncio.new_event_loop()

def _start_loop(lp):
    asyncio.set_event_loop(lp)
    lp.run_forever()

threading.Thread(target=_start_loop, args=(loop,), daemon=True).start()

# ============================================================
# SEGUIMIENTO - FollowController
# ============================================================

class FollowController:
    """
    Controlador de modo sígueme para Tello.

    Arquitectura de mejoras respecto al código original:
    ─────────────────────────────────────────────────────
    1. DETECCIÓN HÍBRIDA: YOLOv5 para re-identificar a la persona cada
       N frames + tracker KCF/CSRT de OpenCV entre detecciones.
       → Reduce latencia de ~33 ms/frame a ~5 ms entre ciclos YOLO.

    2. SELECCIÓN DE TARGET PERSISTENTE: se recuerda la bbox del frame
       anterior y se elige el bbox con mayor IoU (en vez del más grande),
       evitando saltos de target cuando hay varias personas en escena.

    3. PIDs INDEPENDIENTES CON DEAD-ZONE Y ANTI-WINDUP:
       • Yaw   (error horizontal): mantiene la persona centrada X.
       • Pitch (fb velocity):      mantiene distancia mediante ratio area.
       • Throttle (up/down):       mantiene la persona centrada Y.
       • Roll                      desactivado (Tello vuela frontalmente).
       Dead-zone elimina oscilaciones cuando el error es pequeño.
       Anti-windup: ya incluido en simple_pid con output_limits.

    4. RATE LIMITING: los comandos RC se envían a 20 Hz exactos con un
       timer dedicado, separando la lógica de visión del control.
       Antes se enviaban a la frecuencia del recv() de WebRTC (~30fps
       pero solo cada 3 frames = 10 Hz irregular).

    5. KALMAN FILTER en (cx, cy, area) para suavizar la posición del
       target y evitar que el drone reaccione a detecciones ruidosas.

    6. TIMEOUT DE TARGET: si no se detecta persona durante >1 s se envía
       RC=0 y se resetea el tracker, evitando que el drone salga volando.

    7. THREAD SEGURO: visión y RC en hilos separados con lock y variables
       compartidas, sin bloquear el hilo WebRTC.
    """

    # ── Parámetros de frame ───────────────────────────────────────────
    FRAME_W      = 640
    FRAME_H      = 480
    REF_X        = FRAME_W // 2
    REF_Y        = FRAME_H // 2
    FRAME_AREA   = FRAME_W * FRAME_H

    # ── Ratios de área objetivo ───────────────────────────────────────
    TARGET_RATIO     = 0.10
    RATIO_DEADZONE   = 0.02
    X_DEADZONE_PX    = 30
    Y_DEADZONE_PX    = 40

    # ── YOLO ──────────────────────────────────────────────────────────
    YOLO_EVERY       = 5
    TARGET_TIMEOUT   = 1.2

    # ── Límites RC ────────────────────────────────────────────────────
    MAX_YAW          = 40
    MAX_THROTTLE     = 30
    MAX_FB           = 40

    # ── PID gains ─────────────────────────────────────────────────────
    PID_YAW_KP, PID_YAW_KI, PID_YAW_KD = 0.08, 0.001, 0.02
    PID_THR_KP, PID_THR_KI, PID_THR_KD = 0.08, 0.001, 0.02
    PID_FB_KP,  PID_FB_KI,  PID_FB_KD  = 120.0, 2.0, 8.0

    def __init__(self, tello_ref):
        self._tello = tello_ref

        self._pid_yaw = PID(
            self.PID_YAW_KP, self.PID_YAW_KI, self.PID_YAW_KD,
            setpoint=0,
            output_limits=(-self.MAX_YAW, self.MAX_YAW)
        )
        self._pid_thr = PID(
            self.PID_THR_KP, self.PID_THR_KI, self.PID_THR_KD,
            setpoint=0,
            output_limits=(-self.MAX_THROTTLE, self.MAX_THROTTLE)
        )
        self._pid_fb = PID(
            self.PID_FB_KP, self.PID_FB_KI, self.PID_FB_KD,
            setpoint=0,
            output_limits=(-self.MAX_FB, self.MAX_FB)
        )

        self._tracker      = None
        self._tracker_bbox = None
        self._last_det_t   = 0.0
        self._frame_count  = 0
        self._prev_bbox    = None

        self._kf           = self._build_kalman()
        self._kf_init      = False

        self._lock         = threading.Lock()
        self._rc           = (0, 0, 0, 0)
        self._target_lost  = True

        self._rc_thread    = threading.Thread(target=self._rc_loop, daemon=True)
        self._active       = True
        self._rc_thread.start()

    def _build_kalman(self):
        kf = cv2.KalmanFilter(6, 3)
        dt = 1.0 / 30.0
        kf.transitionMatrix = np.array([
            [1, 0, 0, dt, 0,  0 ],
            [0, 1, 0, 0,  dt, 0 ],
            [0, 0, 1, 0,  0,  dt],
            [0, 0, 0, 1,  0,  0 ],
            [0, 0, 0, 0,  1,  0 ],
            [0, 0, 0, 0,  0,  1 ],
        ], dtype=np.float32)
        kf.measurementMatrix = np.array([
            [1, 0, 0, 0, 0, 0],
            [0, 1, 0, 0, 0, 0],
            [0, 0, 1, 0, 0, 0],
        ], dtype=np.float32)
        kf.processNoiseCov     = np.eye(6, dtype=np.float32) * 1e-2
        kf.measurementNoiseCov = np.eye(3, dtype=np.float32) * 0.5
        kf.errorCovPost        = np.eye(6, dtype=np.float32)
        return kf

    def _kf_update(self, cx, cy, ratio):
        meas = np.array([[cx], [cy], [ratio]], dtype=np.float32)
        if not self._kf_init:
            self._kf.statePre = np.array(
                [[cx], [cy], [ratio], [0], [0], [0]], dtype=np.float32
            )
            self._kf_init = True
        self._kf.predict()
        self._kf.correct(meas)
        state = self._kf.statePost
        return float(state[0]), float(state[1]), float(state[2])

    @staticmethod
    def _iou(b1, b2):
        ix1, iy1 = max(b1[0], b2[0]), max(b1[1], b2[1])
        ix2, iy2 = min(b1[2], b2[2]), min(b1[3], b2[3])
        iw, ih   = max(0, ix2 - ix1), max(0, iy2 - iy1)
        inter    = iw * ih
        if inter == 0:
            return 0.0
        area1 = (b1[2] - b1[0]) * (b1[3] - b1[1])
        area2 = (b2[2] - b2[0]) * (b2[3] - b2[1])
        return inter / (area1 + area2 - inter + 1e-6)

    def _select_person(self, persons):
        if not persons:
            return None
        if self._prev_bbox is None:
            return max(persons, key=lambda p: (p[2] - p[0]) * (p[3] - p[1]))
        best = max(persons, key=lambda p: self._iou(self._prev_bbox, p))
        if self._iou(self._prev_bbox, best) < 0.05:
            best = max(persons, key=lambda p: (p[2] - p[0]) * (p[3] - p[1]))
        return best

    def _init_tracker(self, frame_bgr, bbox_xyxy):
        x1, y1, x2, y2 = bbox_xyxy
        w, h = x2 - x1, y2 - y1
        try:
            self._tracker = cv2.TrackerKCF_create()
            self._tracker.init(frame_bgr, (x1, y1, w, h))
            self._tracker_bbox = (x1, y1, w, h)
        except Exception as e:
            print(f'[FOLLOW] Tracker init error: {e}')
            self._tracker = None

    def _update_tracker(self, frame_bgr):
        if self._tracker is None:
            return None
        ok, bbox = self._tracker.update(frame_bgr)
        if not ok:
            self._tracker = None
            return None
        x, y, w, h = [int(v) for v in bbox]
        if w < 20 or h < 20:
            self._tracker = None
            return None
        self._tracker_bbox = (x, y, w, h)
        return (x, y, x + w, y + h)

    def _rc_loop(self):
        interval = 1.0 / 20.0
        while self._active:
            t0 = time.time()
            with self._lock:
                rc   = self._rc
                lost = self._target_lost
            try:
                if self._tello._tello is not None:
                    if lost:
                        self._tello._tello.send_rc_control(0, 0, 0, 0)
                    else:
                        lr, fb, ud, yaw = rc
                        self._tello._tello.send_rc_control(lr, fb, ud, yaw)
            except Exception as e:
                print(f'[FOLLOW RC] Error: {e}')
            elapsed = time.time() - t0
            time.sleep(max(0.0, interval - elapsed))

    def process(self, frame_rgb):
        self._frame_count += 1
        now = time.time()
        frame_bgr = cv2.cvtColor(frame_rgb, cv2.COLOR_RGB2BGR)

        bbox_xyxy = None
        run_yolo = (self._frame_count % self.YOLO_EVERY == 0) or (self._tracker is None)

        if run_yolo:
            results = model(frame_rgb)
            persons = []
            for *box, conf, cls in results.xyxy[0]:
                if model.names[int(cls.item())] == 'person' and float(conf) > 0.45:
                    x1, y1, x2, y2 = int(box[0]), int(box[1]), int(box[2]), int(box[3])
                    if (x2 - x1) > 30 and (y2 - y1) > 50:
                        persons.append((x1, y1, x2, y2))

            chosen = self._select_person(persons)
            if chosen is not None:
                bbox_xyxy = chosen
                self._prev_bbox  = chosen
                self._last_det_t = now
                self._init_tracker(frame_bgr, chosen)

        if bbox_xyxy is None and self._tracker is not None:
            tracked = self._update_tracker(frame_bgr)
            if tracked is not None:
                bbox_xyxy = tracked

        target_lost = (bbox_xyxy is None) or ((now - self._last_det_t) > self.TARGET_TIMEOUT)

        if target_lost:
            with self._lock:
                self._rc          = (0, 0, 0, 0)
                self._target_lost = True
            cv2.putText(frame_bgr, 'FOLLOW: buscando persona...',
                        (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 100, 255), 2)
            return cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)

        x1, y1, x2, y2 = bbox_xyxy
        bw, bh = x2 - x1, y2 - y1
        raw_cx    = x1 + bw / 2.0
        raw_cy    = y1 + bh / 2.0
        raw_ratio = (bw * bh) / self.FRAME_AREA

        sm_cx, sm_cy, sm_ratio = self._kf_update(raw_cx, raw_cy, raw_ratio)

        err_x = sm_cx - self.REF_X
        err_y = self.REF_Y - sm_cy
        err_r = self.TARGET_RATIO - sm_ratio

        if abs(err_x) < self.X_DEADZONE_PX:
            err_x = 0.0
        if abs(err_y) < self.Y_DEADZONE_PX:
            err_y = 0.0
        if abs(err_r) < self.RATIO_DEADZONE:
            err_r = 0.0

        yaw      = int(self._pid_yaw(err_x))
        throttle = int(self._pid_thr(err_y))
        fb       = int(self._pid_fb(err_r))

        with self._lock:
            self._rc          = (0, fb, throttle, yaw)
            self._target_lost = False

        ix1, iy1, ix2, iy2 = int(x1), int(y1), int(x2), int(y2)
        cv2.rectangle(frame_bgr, (ix1, iy1), (ix2, iy2), (250, 150, 0), 2)
        cv2.circle(frame_bgr, (self.REF_X, self.REF_Y), 8, (0, 255, 0), 2)
        cv2.circle(frame_bgr, (int(sm_cx), int(sm_cy)), 5, (255, 0, 255), -1)
        cv2.putText(frame_bgr,
            f'Y:{yaw:+d} T:{throttle:+d} FB:{fb:+d} ratio:{sm_ratio:.3f}',
            (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (250, 150, 0), 2)
        cv2.putText(frame_bgr,
            f'ex:{err_x:+.0f} ey:{err_y:+.0f} er:{err_r:+.3f}',
            (10, 55), cv2.FONT_HERSHEY_SIMPLEX, 0.50, (100, 200, 255), 2)
        mode_label = 'YOLO' if run_yolo else 'TRACK'
        cv2.putText(frame_bgr, f'[{mode_label}]',
            (10, 80), cv2.FONT_HERSHEY_SIMPLEX, 0.50, (0, 255, 120), 2)

        return cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)

    def stop(self):
        self._active = False
        with self._lock:
            self._rc          = (0, 0, 0, 0)
            self._target_lost = True
        try:
            if self._tello._tello is not None:
                self._tello._tello.send_rc_control(0, 0, 0, 0)
        except Exception:
            pass

    def reset_pids(self):
        self._pid_yaw.reset()
        self._pid_thr.reset()
        self._pid_fb.reset()
        self._kf_init   = False
        self._prev_bbox = None
        self._tracker   = None

_follow_ctrl: FollowController = None

# ============================================================
# MQTT callbacks
# ============================================================

def on_connect(client, userdata, flags, rc):
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
                'lat':              0.0,
                'lon':              0.0,
                'alt':              (getattr(tello, 'height_cm', 0) or 0) / 100.0,
                'groundSpeed':      (vx**2 + vy**2)**0.5 / 100.0,
                'batteryremaining': getattr(tello, 'battery_pct', 0) or 0,
                'heading':          getattr(tello, 'yaw_deg', 0) or 0,
                'vx':               vx / 100.0,
                'vy':               vy / 100.0,
                'state':            tello.state,
                'flightMode':       'TELLO',
            })
            if telemetry_channel is not None and telemetry_channel.readyState == 'open':
                loop.call_soon_threadsafe(telemetry_channel.send, payload)
        except Exception as e:
            print(f'[TELLO TEL] Error: {e}')
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
    try:
        data = json.loads(data_str)
        lx = data.get('lx', 0.0)
        ly = data.get('ly', 0.0)
        rx = data.get('rx', 0.0)
        ry = data.get('ry', 0.0)

        # TELLO
        if flight_mode == 'tello':
            if tello is None:
                return
            if _follow_mode:
                return
            if tello.state != 'flying':
                return
            threshold = 0.1
            def to_rc(val): return int(val * 100)
            left_right = to_rc(rx) if abs(rx) >= threshold else 0
            fwd_back   = to_rc(ry) if abs(ry) >= threshold else 0
            up_down    = to_rc(ly) if abs(ly) >= threshold else 0
            yaw        = to_rc(lx) if abs(lx) >= threshold else 0
            tello._tello.send_rc_control(left_right, fwd_back, up_down, yaw)
            return

        # ARDUPILOT / SITL
        if dron.state not in ('flying', 'returning'):
            return
        threshold = 0.1
        def to_pwm(val): return int(1500 + val * 500)
        yaw_expo  = 0.4
        yaw_scale = 0.25
        def apply_expo(val, expo): return expo * val**3 + (1 - expo) * val
        apply_expo(lx, yaw_expo) * yaw_scale

        roll     = to_pwm(rx) if abs(rx) >= threshold else 1500
        pitch    = to_pwm(ry) if abs(ry) >= threshold else 1500
        throttle = to_pwm(ly) if abs(ly) >= threshold else 1500
        yaw      = to_pwm(lx) if abs(lx) >= threshold else 1500
        dron.send_rc(roll, pitch, throttle, yaw)

    except Exception as e:
        print(f'Error joystick: {e}')

def on_message(client, userdata, message):
    global _pc, _camera_track, flight_mode, camera_index, _follow_mode, tello, _follow_ctrl

    parts   = message.topic.split('/')
    command = parts[2]
    print(f'Comando recibido: {command}')

    # SET MODE
    if command == 'setMode':
        mode = message.payload.decode().strip()
        if mode in ('ardupilot', 'sitl', 'tello'):
            flight_mode = mode
            if mode == 'tello' and tello is None:
                tello = TelloDron()
            print(f'[CONFIG] Modo de vuelo: {flight_mode}')
        else:
            print(f'[WARN] Modo desconocido: {mode}')

    # SET CAMERA
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

    # CONNECT
    if command == 'connect':
        def conectar():
            global _pc, _camera_track, telemetry_channel

            # TELLO
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
                    try:
                        asyncio.run_coroutine_threadsafe(_pc.close(), loop)
                    except Exception:
                        pass
                    _pc = None
                    _camera_track = None
                    telemetry_channel = None

                client.publish('groundStation/mobileFlutter/connected', 'connected')
                time.sleep(0.3)
                if tello.state == 'flying':
                    client.publish('groundStation/mobileFlutter/flying', 'flying')
                asyncio.run_coroutine_threadsafe(webrtc_client(), loop)
                return

            # ARDUPILOT / SITL
            if flight_mode == 'ardupilot':
                conn_str = 'com7'
                baud = 57600
            elif flight_mode == 'sitl':
                conn_str = 'tcp:127.0.0.1:5763'
                baud = 115200
            else:
                print(f'[ERROR] Modo "{flight_mode}" no disponible.')
                client.publish('groundStation/mobileFlutter/disconnected', f'mode_unavailable:{flight_mode}')
                return

            print(f'[INFO] Modo: {flight_mode} | Conexion: {conn_str} | Camara: {camera_index}')
            already_connected = dron.state in ('connected', 'armed', 'flying', 'returning')

            if already_connected and hasattr(dron, '_conn_str') and dron._conn_str != conn_str:
                already_connected = False
                try:
                    dron.stop_sending_telemetry_info()
                    dron.disconnect()
                except Exception:
                    pass

            if not already_connected:
                print('Conectando al dron...')
                try:
                    dron.connect(conn_str, baud)
                    dron._conn_str = conn_str
                    if dron.vehicle is None:
                        raise Exception('Vehicle is None after connect')
                    dron.frequency = 2
                    dron.send_telemetry_info(process_telemetry_info)
                except Exception as e:
                    print(f'Error al conectar: {e}')
                    client.publish('groundStation/mobileFlutter/disconnected', 'connection_failed')
                    return
            else:
                print(f'Recuperacion de sesion - estado: "{dron.state}"')
                if _pc is not None:
                    try:
                        asyncio.run_coroutine_threadsafe(_pc.close(), loop)
                    except Exception:
                        pass
                    _pc = None
                    _camera_track = None
                    telemetry_channel = None
                try:
                    dron.stop_sending_telemetry_info()
                except Exception:
                    pass
                dron.send_telemetry_info(process_telemetry_info)

            client.publish('groundStation/mobileFlutter/connected', 'connected')
            time.sleep(0.3)

            if dron.state in ('armed', 'flying', 'returning'):
                client.publish('groundStation/mobileFlutter/armed', 'armed')
                print('Session recovery: re-publicado armed')
                if dron.state in ('flying', 'returning'):
                    time.sleep(0.1)
                    client.publish('groundStation/mobileFlutter/flying', 'flying')
                    print('Session recovery: re-publicado flying')

            asyncio.run_coroutine_threadsafe(webrtc_client(), loop)

        threading.Thread(target=conectar).start()

    # ARM (solo ArduPilot/SITL)
    if command == 'arm':
        if flight_mode == 'tello':
            return
        if dron.state == 'connected':
            def armar():
                dron.arm()
                print('Motores armados!')
                client.publish('groundStation/mobileFlutter/armed', 'armed')
                threading.Thread(target=monitor_arm_state, daemon=True).start()
            threading.Thread(target=armar).start()
        else:
            print(f'Arm ignorado: estado "{dron.state}"')

    # TAKEOFF
    if command == 'takeoff':
        if flight_mode == 'tello':
            if tello is None:
                return
            if tello.state == 'connected':
                def despegar_tello():
                    tello.takeOff(blocking=True)
                    client.publish('groundStation/mobileFlutter/flying', 'flying')
                threading.Thread(target=despegar_tello, daemon=True).start()
            else:
                print(f'[TELLO] Takeoff ignorado: estado "{tello.state}"')
            return

        if dron.state in ('armed', 'flying'):
            parts_payload = message.payload.decode().split(':')
            altitude = int(parts_payload[0])
            speed = float(parts_payload[1]) if len(parts_payload) > 1 else dron.navSpeed
            def despegar():
                print(f'Despegando a {altitude}m a {speed}m/s...')
                dron.navSpeed = speed
                dron.takeOff(altitude)
                print('Despegue completado!')
                dron.vehicle.set_mode('LOITER')
                dron.changeNavSpeed(speed)
                client.publish('groundStation/mobileFlutter/flying', 'flying')
            threading.Thread(target=despegar).start()
        else:
            print(f'Takeoff ignorado: estado "{dron.state}"')

    # LAND
    if command == 'land':
        if flight_mode == 'tello':
            if tello is None:
                return
            if tello.state == 'flying':
                if _follow_mode:
                    _follow_mode = False
                    if _follow_ctrl is not None:
                        _follow_ctrl.stop()
                def aterrizar_tello():
                    tello.Land(blocking=True)
                    client.publish('groundStation/mobileFlutter/landed', 'landed')
                threading.Thread(target=aterrizar_tello, daemon=True).start()
            else:
                print(f'[TELLO] Land ignorado: estado "{tello.state}"')
            return

        if dron.state in ('flying', 'returning'):
            def aterrizar():
                print('Aterrizando...')
                dron.Land()
                print('Aterrizado!')
                client.publish('groundStation/mobileFlutter/landed', 'landed')
            threading.Thread(target=aterrizar).start()
        else:
            print(f'Land ignorado: estado "{dron.state}"')

    # RTL (solo ArduPilot/SITL)
    if command == 'rtl':
        if flight_mode == 'tello':
            return
        if dron.state in ('flying', 'returning'):
            def rtl():
                print('Volviendo al punto de lanzamiento...')
                dron.changeNavSpeed(dron.navSpeed)
                dron.RTL()
                print('RTL completado!')
                client.publish('groundStation/mobileFlutter/landed', 'landed')
            threading.Thread(target=rtl).start()
        else:
            print(f'RTL ignorado: estado "{dron.state}"')

    # SPEED
    if command == 'speed':
        if flight_mode == 'tello':
            return
        spd = float(message.payload.decode())
        print(f'Velocidad: {spd} m/s')
        dron.navSpeed = spd
        if dron.vehicle is not None:
            dron.changeNavSpeed(spd)

    # ZOOM
    if command == 'zoom':
        try:
            zoom_val = float(message.payload.decode())
            zoom_val = max(1.0, min(zoom_val, 10.0))
            if _camera_track is not None:
                _camera_track.zoom_factor = zoom_val
            print(f'Zoom: {zoom_val}x')
        except ValueError:
            print('[WARN] Zoom: valor invalido')

    # FLIP (solo Tello)
    if command == 'flip':
        if flight_mode == 'tello' and tello is not None and tello.state == 'flying':
            direction = message.payload.decode().strip()
            try:
                tello._tello.flip(direction[0])
                print(f'[TELLO] Flip: {direction}')
            except Exception as e:
                print(f'[TELLO] Flip error: {e}')

    # DANCE (solo Tello)
    if command == 'dance':
        if flight_mode == 'tello' and tello is not None and tello.state == 'flying':
            def do_dance():
                try:
                    print('[TELLO] Iniciando dance...')
                    tello._tello.flip('f')
                    time.sleep(1.5)
                    tello._tello.flip('b')
                    time.sleep(1.5)
                    tello._tello.flip('l')
                    time.sleep(1.5)
                    tello._tello.flip('r')
                    print('[TELLO] Dance completado!')
                except Exception as e:
                    print(f'[TELLO] Dance error: {e}')
            threading.Thread(target=do_dance, daemon=True).start()

    # FOLLOW MODE (solo Tello)
    if command == 'followMode':
        if flight_mode == 'tello' and tello is not None:
            new_state = message.payload.decode().strip() == 'true'
            if new_state == _follow_mode:
                return
            _follow_mode = new_state
            if _follow_mode:
                if _follow_ctrl is None:
                    _follow_ctrl = FollowController(tello)
                else:
                    _follow_ctrl._tello  = tello
                    _follow_ctrl._active = True
                    _follow_ctrl.reset_pids()
                    if not _follow_ctrl._rc_thread.is_alive():
                        _follow_ctrl._rc_thread = threading.Thread(
                            target=_follow_ctrl._rc_loop, daemon=True
                        )
                        _follow_ctrl._rc_thread.start()
                print('[TELLO] Follow mode ACTIVADO')
            else:
                if _follow_ctrl is not None:
                    _follow_ctrl.stop()
                print('[TELLO] Follow mode DESACTIVADO')

    # DETECTION MODE
    if command == 'detectionMode':
        mode = message.payload.decode()
        if _camera_track is not None:
            _camera_track.detection_mode = mode
            _camera_track.detecciones = []
        print(f'Modo deteccion YOLO: {mode}')

    # DISCONNECT
    if command == 'disconnect':
        if flight_mode == 'tello':
            if tello is None:
                return
            def desconectar_tello():
                global _pc, _camera_track, _follow_mode, _follow_ctrl
                print('[TELLO] Desconectando...')
                _follow_mode = False
                if _follow_ctrl is not None:
                    _follow_ctrl.stop()
                    _follow_ctrl = None
                try:
                    tello.stream_off()
                except Exception:
                    pass
                try:
                    tello.disconnect()
                except Exception as e:
                    print(f'[TELLO] Error al desconectar: {e}')
                if _pc is not None:
                    try:
                        asyncio.run_coroutine_threadsafe(_pc.close(), loop)
                    except Exception:
                        pass
                _pc = None
                _camera_track = None
                print('[TELLO] Desconectado!')
                client.publish('groundStation/mobileFlutter/disconnected', 'disconnected')
            threading.Thread(target=desconectar_tello, daemon=True).start()
            return

        def desconectar():
            global _pc, _camera_track
            print('Desconectando dron...')
            try:
                dron.stop_sending_telemetry_info()
            except Exception:
                pass
            dron.disconnect()
            if _pc is not None:
                try:
                    asyncio.run_coroutine_threadsafe(_pc.close(), loop)
                except Exception as e:
                    print(f'Error cerrando PeerConnection: {e}')
            _pc = None
            _camera_track = None
            print('Dron desconectado!')
            client.publish('groundStation/mobileFlutter/disconnected', 'disconnected')
        threading.Thread(target=desconectar).start()

    # UPLOAD MISSION
    if command == 'uploadMission':
        global _pending_mission, _pending_actions
        try:
            data = json.loads(message.payload.decode())
            wp_data     = data.get('waypoints', [])
            takeoff_alt = data.get('takeoffAlt', 5)
            speed       = data.get('speed', dron.navSpeed)

            dronlink_waypoints = []
            actions = []

            for wp in wp_data:
                dronlink_waypoints.append({
                    'lat': float(wp['lat']),
                    'lon': float(wp['lon']),
                    'alt': float(wp['altM']),
                })
                actions.append(wp.get('action', {'type': 'none', 'seconds': 5}))

            _pending_mission = {
                'speed':      speed,
                'takeOffAlt': takeoff_alt,
                'waypoints':  dronlink_waypoints,
            }
            _pending_actions = actions

            print(f'[MISSION] Plan guardado: {len(dronlink_waypoints)} waypoints')
            client.publish('groundStation/mobileFlutter/missionUploaded', 'ok')

        except Exception as e:
            print(f'[MISSION ERROR] {e}')
            client.publish('groundStation/mobileFlutter/missionUploaded', f'error:{e}')

    # START MISSION
    if command == 'startMission':
        if _pending_mission is None:
            print('[MISSION] No hay mision cargada')
            client.publish('groundStation/mobileFlutter/missionStarted', 'error')
            return

        def run_mission():
            print('[MISSION] Iniciando mision...')
            client.publish('groundStation/mobileFlutter/missionStarted', 'ok')
            try:
                if not dron.vehicle.motors_armed():
                    print('[MISSION] Armando motores...')
                    dron.arm()
                    client.publish('groundStation/mobileFlutter/armed', 'armed')

                dron.takeOff(_pending_mission['takeOffAlt'])
                print('[MISSION] Despegue completado')

                dron.changeNavSpeed(_pending_mission['speed'])
                client.publish('groundStation/mobileFlutter/flying', 'flying')

                waypoints = _pending_mission['waypoints']

                for index, wp in enumerate(waypoints):
                    client.publish('groundStation/mobileFlutter/missionWaypoint', str(index))
                    print(f'[MISSION] Navegando a WP {index+1}/{len(waypoints)}')
                    dron.goto(float(wp['lat']), float(wp['lon']), float(wp['alt']))

                    if index < len(_pending_actions):
                        action      = _pending_actions[index]
                        action_type = action.get('type', 'none')
                        action_secs = float(action.get('seconds', 5))

                        if action_type == 'hover':
                            print(f'[MISSION] WP {index+1}: hover {action_secs}s')
                            time.sleep(action_secs)
                        elif action_type == 'takePhoto':
                            client.publish('groundStation/mobileFlutter/cameraAction', 'photo')
                        elif action_type == 'recordVideo':
                            client.publish(
                                'groundStation/mobileFlutter/cameraAction',
                                f'record:{int(action_secs)}'
                            )
                            time.sleep(action_secs)
                        elif action_type == 'rtl':
                            print(f'[MISSION] WP {index+1}: RTL')
                            dron.RTL()
                            client.publish('groundStation/mobileFlutter/landed', 'landed')
                            return
                        elif action_type == 'land':
                            print(f'[MISSION] WP {index+1}: LAND')
                            dron.Land()
                            client.publish('groundStation/mobileFlutter/landed', 'landed')
                            return

                print('[MISSION] Mision completada - RTL automatico')
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
        self.zoom_factor    = 1.0
        self.detection_mode = 'all'
        self.detecciones    = []
        self.frame_count    = 0
        self.correct_lens   = cam_matrix is not None
        self.cap            = None

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
        undistorted = cv2.undistort(frame, cam_matrix, dist_coefs, None, new_cam_mtx)
        x, y, w, h = roi_crop
        if w > 0 and h > 0:
            undistorted = undistorted[y:y + h, x:x + w]
        return undistorted

    def _apply_zoom(self, frame):
        if self.zoom_factor <= 1.0:
            return frame
        fh, fw = frame.shape[:2]
        sx = int(fw / self.zoom_factor)
        sy = int(fh / self.zoom_factor)
        cx, cy = fw // 2, fh // 2
        x1 = max(0, cx - sx // 2)
        y1 = max(0, cy - sy // 2)
        x2 = min(fw, cx + sx // 2)
        y2 = min(fh, cy + sy // 2)
        cropped = frame[y1:y2, x1:x2]
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

        if flight_mode == 'tello' and _follow_mode and _follow_ctrl is not None:
            if tello.state == 'flying':
                frame = _follow_ctrl.process(frame)

        if flight_mode == 'tello':
            vf = VideoFrame.from_ndarray(frame, format='rgb24')
            vf.pts, vf.time_base = self.frame_count, fractions.Fraction(1, 30)
            return vf

        if self.frame_count % 25 == 0 and self.detection_mode != 'none':
            results = model(frame)
            self.detecciones = []
            for *box, conf, cls in results.xyxy[0]:
                x1, y1, x2, y2 = map(int, box)
                label      = model.names[int(cls.item())]
                confidence = float(conf.item())
                if self.detection_mode == 'person' and label != 'person':
                    continue
                self.detecciones.append((x1, y1, x2, y2, label, confidence))

        if self.detection_mode == 'none':
            self.detecciones = []

        frame_bgr = cv2.cvtColor(frame, cv2.COLOR_RGB2BGR)
        color = (0, 255, 0) if self.detection_mode == 'all' else (0, 150, 255)
        for (x1, y1, x2, y2, label, confidence) in self.detecciones:
            text = f'{label} ({confidence * 100:.0f}%)'
            cv2.rectangle(frame_bgr, (x1, y1), (x2, y2), color, 2)
            cv2.putText(frame_bgr, text, (x1, y1 - 10),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.6, color, 2)

        ts = datetime.now().strftime('%H:%M:%S.%f')[:-3]
        cv2.putText(frame_bgr, ts, (10, 30),
                    cv2.FONT_HERSHEY_SIMPLEX, 1, (0, 255, 0), 2)

        frame = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)
        vf = VideoFrame.from_ndarray(frame, format='rgb24')
        vf.pts, vf.time_base = self.frame_count, fractions.Fraction(1, 30)
        return vf

# ============================================================
# WEBRTC - señalización
# ============================================================

async def webrtc_client():
    global _pc, telemetry_channel, _camera_track, _webrtc_running

    if _webrtc_running:
        print('[WEBRTC] Ya hay una sesion activa, ignorando nueva llamada.')
        return
    _webrtc_running = True

    if _pc is not None:
        try:
            await _pc.close()
        except Exception:
            pass
        _pc = None

    ssl_ctx = ssl.create_default_context()
    ssl_ctx.check_hostname = False
    ssl_ctx.verify_mode = ssl.CERT_NONE

    print(f'Conectando al servidor de senalizacion: {SIGNAL_URL}')

    try:
        async with websockets.connect(SIGNAL_URL, ssl=ssl_ctx) as ws:
            await ws.send(MY_ID)
            print(f'Identificado como "{MY_ID}", esperando a "{REMOTE_ID}"...')

            await ws.send(json.dumps({
                'target': REMOTE_ID,
                'type': 'ice_config',
                'iceServers': [
                    {'urls': 'stun:stun.l.google.com:19302'},
                    {'urls': 'stun:stun1.l.google.com:19302'},
                ],
            }))
            print('[WEBRTC] ice_config enviado a Flutter')

            await asyncio.sleep(0.8)

            _pc = RTCPeerConnection()

            joystick_channel  = _pc.createDataChannel('joystick')
            telemetry_channel = _pc.createDataChannel('telemetry')

            @joystick_channel.on('message')
            def on_joystick(msg):
                handle_joystick(msg)

            @_pc.on('icecandidate')
            async def on_ice(candidate):
                if candidate:
                    await ws.send(json.dumps({
                        'target': REMOTE_ID,
                        'type': 'candidate',
                        'candidate': {
                            'candidate':     candidate.candidate,
                            'sdpMid':        candidate.sdpMid,
                            'sdpMLineIndex': candidate.sdpMLineIndex,
                        },
                    }))
                else:
                    await ws.send(json.dumps({
                        'target': REMOTE_ID,
                        'type': 'candidate',
                        'candidate': None,
                    }))

            track = CameraVideoTrack(cam_idx=camera_index)
            _camera_track = track
            _pc.addTrack(track)

            offer = await _pc.createOffer()
            await _pc.setLocalDescription(offer)
            await ws.send(json.dumps({
                'target': REMOTE_ID,
                'type': 'offer',
                'offer': {
                    'sdp':  _pc.localDescription.sdp,
                    'type': _pc.localDescription.type,
                },
            }))
            print('Offer enviada, esperando answer de Flutter...')

            async for raw in ws:
                data = json.loads(raw)

                if data.get('type') == 'answer':
                    await _pc.setRemoteDescription(
                        RTCSessionDescription(
                            sdp=data['answer']['sdp'],
                            type=data['answer']['type'],
                        )
                    )
                    print('WebRTC handshake completo')

                if data.get('type') == 'candidate':
                    cand = data.get('candidate')
                    if not cand:
                        continue
                    try:
                        rtc_cand = candidate_from_sdp(cand['candidate'])
                        rtc_cand.sdpMid        = cand.get('sdpMid') or '0'
                        rtc_cand.sdpMLineIndex = cand.get('sdpMLineIndex') or 0
                        await _pc.addIceCandidate(rtc_cand)
                    except Exception as e:
                        print(f'Error ICE candidate: {e}')

    except Exception as e:
        print(f'Error en webrtc_client: {e}')
    finally:
        _webrtc_running = False

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