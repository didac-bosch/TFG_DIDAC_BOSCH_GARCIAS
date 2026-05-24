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

from dronLink.Dron import Dron
from TelloLink.Tello import TelloDron

# ============================================================
# CONSTANTES
# ============================================================

BROKER     = 'broker.hivemq.com'
PORT_MQTT  = 1883
SIGNAL_URL = 'wss://dronseetac.upc.edu:8105/ws'

MY_ID     = 'python'
REMOTE_ID = 'browser'

# ============================================================
# CONFIGURACION DINAMICA
# ============================================================

flight_mode  = 'ardupilot'   # 'ardupilot' | 'sitl' | 'tello'
camera_index = 1

# ============================================================
# ESTADO GLOBAL
# ============================================================

_monitoring       = False
_pc               = None
_webrtc_running   = False
telemetry_channel = None
_camera_track     = None
_pending_mission  = None
_pending_actions  = []
_follow_mode      = False
_orbit_active     = False
_orbit_thread     = None

# ============================================================
# CALIBRACION CAMARA
# ============================================================

CALIB_FILE  = 'calibration_data_px.yaml'
cam_matrix  = None
dist_coefs  = None
new_cam_mtx = None
roi_crop    = None

def load_calibration():
    global cam_matrix, dist_coefs, new_cam_mtx, roi_crop
    if not os.path.exists(CALIB_FILE):
        print(f'[WARN] "{CALIB_FILE}" no encontrado - correccion de lente desactivada.')
        return
    with open(CALIB_FILE) as f:
        data = yaml.safe_load(f)
    cam_matrix  = np.array(data['camera_matrix'])
    dist_coefs  = np.array(data['distortion_coefficients'])
    h, w        = 480, 640
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
pose_model = YOLO('yolov8n-pose.pt')

# ============================================================
# LOOP ASYNCIO
# ============================================================

loop = asyncio.new_event_loop()

def _start_loop(lp):
    asyncio.set_event_loop(lp)
    lp.run_forever()

threading.Thread(target=_start_loop, args=(loop,), daemon=True).start()

# ============================================================
# FOLLOW CONTROLLER
# ============================================================


class FollowController:

    FRAME_W = 960
    FRAME_H = 720

    TARGET_RATIO        = 0.30
    RATIO_DEADZONE      = 0.03

    X_DEADZONE_PX       = 35
    Y_DEADZONE_PX       = 60

    YOLO_FRAME_STRIDE   = 8
    EMA_ALPHA           = 0.35
    TARGET_LOST_GRACE_S = 1.5

    CONF_THRESHOLD      = 0.45
    MIN_BBOX_W          = 30
    MIN_BBOX_H          = 50

    MAX_YAW             = 40
    MAX_THROTTLE        = 30
    MAX_FB              = 35

    STOP_DISTANCE_CM    = 40.0
    STOP_DEADZONE_CM    = 8.0       # ±8 cm zona muerta ToF
    TOF_ACTIVATION_RATIO = 0.10     
    TOF_EMA_ALPHA       = 0.20      # suavizado agresivo señal ToF

    PID_YAW_KP,     PID_YAW_KI,     PID_YAW_KD     = -0.20, -0.003, -0.05
    PID_THR_KP,     PID_THR_KI,     PID_THR_KD     = 0.25, 0.002, 0.04  
    PID_FB_BBOX_KP, PID_FB_BBOX_KI, PID_FB_BBOX_KD = 300.0,  0.0,   50.0
    PID_FB_TOF_KP,  PID_FB_TOF_KI,  PID_FB_TOF_KD  =  0.10,  0.001,  0.02  # KD reducido

    SEARCH_LOST_S   = 2.0
    SEARCH_YAW      = 20
    SEARCH_SPIN_S   = 6.0

    def __init__(self, tello_ref):
        self._tello = tello_ref

        self._pid_yaw = PID(
            self.PID_YAW_KP, self.PID_YAW_KI, self.PID_YAW_KD,
            setpoint=0, output_limits=(-self.MAX_YAW, self.MAX_YAW))
        self._pid_thr = PID(
            self.PID_THR_KP, self.PID_THR_KI, self.PID_THR_KD,
            setpoint=0, output_limits=(-self.MAX_THROTTLE, self.MAX_THROTTLE))
        self._pid_fb_bbox = PID(
            self.PID_FB_BBOX_KP, self.PID_FB_BBOX_KI, self.PID_FB_BBOX_KD,
            setpoint=0, output_limits=(-self.MAX_FB, self.MAX_FB))
        self._pid_fb_tof = PID(
            self.PID_FB_TOF_KP, self.PID_FB_TOF_KI, self.PID_FB_TOF_KD,
            setpoint=0, output_limits=(-self.MAX_FB, self.MAX_FB))

        self._pitch_source_last = 'none'

        self._sdk_lock    = threading.Lock()
        self.front_tof_cm = -1.0
        self._tof_ema     = -1.0    # EMA interno del ToF

        self._rc_lock = threading.Lock()
        self._rc      = [0, 0, 0, 0]

        self._frame_lock  = threading.Lock()
        self._debug_frame = None

        # Inicializar status para telemetría (evita AttributeError antes del primer frame)
        self._follow_status = 'waiting'
        self._tof_display   = -1.0

        self._active = True

        self._tof_thread = threading.Thread(target=self._tof_loop, daemon=True)
        self._tof_thread.start()
        self._rc_thread = threading.Thread(target=self._rc_loop, daemon=True)
        self._rc_thread.start()
        self._vid_thread = threading.Thread(target=self._video_loop, daemon=True)
        self._vid_thread.start()

    def _tof_loop(self):
        while self._active:
            try:
                with self._sdk_lock:
                    raw = self._tello._tello.send_command_with_return('EXT tof?', timeout=1)
                if raw and raw.strip().startswith('tof '):
                    mm = int(raw.strip().split()[1])
                    raw_cm = -1.0 if mm >= 8190 else mm / 10.0
                    if raw_cm > 0:
                        if self._tof_ema < 0:
                            self._tof_ema = raw_cm          # inicializar EMA
                        else:
                            self._tof_ema = (self.TOF_EMA_ALPHA * raw_cm
                                             + (1 - self.TOF_EMA_ALPHA) * self._tof_ema)
                        self.front_tof_cm = self._tof_ema
                    else:
                        self.front_tof_cm = -1.0
                        self._tof_ema     = -1.0
                else:
                    self.front_tof_cm = -1.0
                    self._tof_ema     = -1.0
            except Exception:
                self.front_tof_cm = -1.0
                self._tof_ema     = -1.0
            time.sleep(0.1)


    def _detect_persons(self, frame_rgb):
        results = pose_model(frame_rgb, imgsz=320, verbose=False)
        persons = []
        for result in results:
            if result.boxes is None:
                continue
            kps = result.keypoints.xy if result.keypoints is not None else None
            for i, (box, conf) in enumerate(zip(result.boxes.xyxy, result.boxes.conf)):
                if float(conf) < self.CONF_THRESHOLD:
                    continue
                x1 = max(0, int(box[0]))
                y1 = max(0, int(box[1]))
                x2 = min(int(box[2]), self.FRAME_W)
                y2 = min(int(box[3]), self.FRAME_H)
                if (x2 - x1) < self.MIN_BBOX_W or (y2 - y1) < self.MIN_BBOX_H:
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

    @staticmethod
    def _iou(b1, b2):
        ix1 = max(b1[0], b2[0]); iy1 = max(b1[1], b2[1])
        ix2 = min(b1[2], b2[2]); iy2 = min(b1[3], b2[3])
        iw  = max(0, ix2 - ix1); ih  = max(0, iy2 - iy1)
        inter = iw * ih
        if inter == 0:
            return 0.0
        a1 = (b1[2]-b1[0]) * (b1[3]-b1[1])
        a2 = (b2[2]-b2[0]) * (b2[3]-b2[1])
        return inter / (a1 + a2 - inter + 1e-6)

    def _select_best_person(self, persons, prev_bbox):
        if not persons:
            return None
        if prev_bbox is None:
            return max(persons, key=lambda p: (p[2]-p[0]) * (p[3]-p[1]))
        best = max(persons, key=lambda p: self._iou(prev_bbox[:4], p[:4]))
        if self._iou(prev_bbox[:4], best[:4]) < 0.05:
            best = max(persons, key=lambda p: (p[2]-p[0]) * (p[3]-p[1]))
        return best

    def _video_loop(self):
        frame_count       = 0
        consecutive_none  = 0
        detected_persons  = []
        prev_bbox         = None

        ema_cx    = float(self.FRAME_W // 2)
        ema_cy    = float(self.FRAME_H // 2)
        ema_ratio = self.TARGET_RATIO
        ema_init  = False

        last_seen_time    = 0.0
        search_start_time = None

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
            ref_x = actual_w // 2
            ref_y = actual_h // 2

            if frame_count % self.YOLO_FRAME_STRIDE == 0:
                detected_persons = self._detect_persons(frame_rgb)

            best = self._select_best_person(detected_persons, prev_bbox)
            now  = time.time()

            if best is not None:
                last_seen_time    = now
                search_start_time = None
                prev_bbox         = best

                x1, y1, x2, y2, shoulder_cy = best
                bw = x2 - x1
                bh = y2 - y1
                raw_cx    = float(x1 + bw / 2.0)
                vertical_offset_px = 80
                raw_cy    = shoulder_cy if shoulder_cy is not None else float(y1 + bh / 2.0) - vertical_offset_px
                raw_ratio = (bw * bh) / float(actual_w * actual_h)

                if not ema_init:
                    ema_cx    = raw_cx
                    ema_cy    = raw_cy
                    ema_ratio = raw_ratio
                    ema_init  = True
                else:
                    a         = self.EMA_ALPHA
                    ema_cx    = a * raw_cx    + (1 - a) * ema_cx
                    ema_cy    = a * raw_cy    + (1 - a) * ema_cy
                    ema_ratio = a * raw_ratio + (1 - a) * ema_ratio

                err_x = ema_cx - ref_x
                if abs(err_x) < self.X_DEADZONE_PX:
                    err_x = 0.0
                yaw = int(self._pid_yaw(err_x))

                err_y = ema_cy - ref_y
                if abs(err_y) < self.Y_DEADZONE_PX:
                    err_y = 0.0
                throttle = int(self._pid_thr(err_y))

                tof_valid = self.front_tof_cm > 0
                use_tof   = tof_valid and (self.front_tof_cm < 100.0)

                if use_tof:
                    err_fb_tof = self.front_tof_cm - self.STOP_DISTANCE_CM
                    if abs(err_fb_tof) < 5.0:
                        fb = 0
                        self._pid_fb_tof.reset()
                        self._pitch_source_last = 'none'
                    else:
                        if self._pitch_source_last != 'tof':
                            self._pid_fb_tof.reset()
                        self._pid_fb_bbox.reset()
                        fb = int(self._pid_fb_tof(err_fb_tof))
                        self._pitch_source_last = 'tof'
                    self._follow_status = 'tof'
                    self._tof_display   = self.front_tof_cm
                else:
                    err_fb_bbox = ema_ratio - self.TARGET_RATIO
                    if abs(err_fb_bbox) < self.RATIO_DEADZONE:
                        fb = 0
                        self._pid_fb_bbox.reset()
                        self._pitch_source_last = 'none'
                    else:
                        if self._pitch_source_last != 'bbox':
                            self._pid_fb_bbox.reset()
                        fb = int(self._pid_fb_bbox(err_fb_bbox))
                        self._pitch_source_last = 'bbox'
                    self._pid_fb_tof.reset()
                    self._follow_status = 'following'
                    self._tof_display   = -1.0

                with self._rc_lock:
                    self._rc = [0, fb, throttle, yaw]

                cv2.rectangle(frame_bgr, (x1, y1), (x2, y2), (250, 150, 0), 2)
                if shoulder_cy is not None:
                    cv2.circle(frame_bgr, (int(raw_cx), int(shoulder_cy)), 6, (0, 255, 255), -1)
                cv2.circle(frame_bgr, (ref_x, ref_y), 8, (0, 255, 0), 2)
                cv2.circle(frame_bgr, (int(ema_cx), int(ema_cy)), 5, (255, 0, 255), -1)
                src_label = f'ToF:{self.front_tof_cm:.0f}cm' if use_tof else f'BBox:{ema_ratio:.3f}'
                cv2.putText(frame_bgr,
                    f'Y:{yaw:+d} T:{throttle:+d} FB:{fb:+d} [{src_label}]',
                    (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (250, 150, 0), 2)
                cv2.putText(frame_bgr,
                    f'ex:{err_x:+.0f} ey:{err_y:+.0f} ratio:{ema_ratio:.3f}',
                    (10, 55), cv2.FONT_HERSHEY_SIMPLEX, 0.50, (100, 200, 255), 2)
                yolo_tick = (frame_count % self.YOLO_FRAME_STRIDE == 0)
                cv2.putText(frame_bgr, '[YOLO]' if yolo_tick else '[EMA]',
                    (10, 80), cv2.FONT_HERSHEY_SIMPLEX, 0.50, (0, 255, 120), 2)
                with self._frame_lock:
                    out = cv2.cvtColor(frame_bgr,cv2.COLOR_BGR2RGB)
                    self._debug_frame = cv2.resize (out, (640,480), interpolation=cv2.INTER_LINEAR)

            elif last_seen_time > 0 and (now - last_seen_time) < self.TARGET_LOST_GRACE_S:
                with self._rc_lock:
                    self._rc = [0, 0, 0, 0]
                self._follow_status = 'grace'
                self._tof_display   = -1.0
                cv2.putText(frame_bgr, 'FOLLOW: grace...',
                    (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 200, 255), 2)
                with self._frame_lock:
                    out = cv2.cvtColor(frame_bgr,cv2.COLOR_BGR2RGB)
                    self._debug_frame = cv2.resize (out, (640,480), interpolation=cv2.INTER_LINEAR)

            else:
                ema_init         = False
                prev_bbox        = None
                detected_persons = []
                self._pid_yaw.reset()
                self._pid_thr.reset()
                self._pid_fb_bbox.reset()
                self._pid_fb_tof.reset()
                self._pitch_source_last = 'none'
                self._tof_display       = -1.0

                if search_start_time is None:
                    search_start_time = now

                time_searching = now - search_start_time

                if time_searching >= self.SEARCH_LOST_S:
                    if time_searching < self.SEARCH_LOST_S + self.SEARCH_SPIN_S:
                        with self._rc_lock:
                            self._rc = [0, 0, 0, self.SEARCH_YAW]
                        self._follow_status = 'searching'
                        label = 'FOLLOW: buscando 360...'
                    else:
                        with self._rc_lock:
                            self._rc = [0, 0, 0, 0]
                        search_start_time   = None
                        self._follow_status = 'lost'
                        label = 'FOLLOW: sin target'
                else:
                    with self._rc_lock:
                        self._rc = [0, 0, 0, 0]
                    self._follow_status = 'waiting'
                    label = f'FOLLOW: esperando... ({self.SEARCH_LOST_S - time_searching:.1f}s)'

                cv2.putText(frame_bgr, label,
                    (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 100, 255), 2)
                with self._frame_lock:
                    out = cv2.cvtColor(frame_bgr,cv2.COLOR_BGR2RGB)
                    self._debug_frame = cv2.resize (out, (640,480), interpolation=cv2.INTER_LINEAR)

    def _rc_loop(self):
        interval = 1.0 / 20.0
        while self._active:
            t0 = time.time()
            with self._rc_lock:
                lr, fb, ud, yaw = self._rc
            try:
                with self._sdk_lock:
                    self._tello.rc(lr, fb, ud, yaw)
            except Exception as e:
                print(e)
            elapsed = time.time() - t0
            time.sleep(max(0.0, interval - elapsed))

    def get_debug_frame(self):
        with self._frame_lock:
            return self._debug_frame

    def stop(self):
        self._active = False
        time.sleep(0.5)
        try:
            self._tello.rc(0, 0, 0, 0)
        except Exception:
            pass

    def reset_pids(self):
        self._pid_yaw.reset()
        self._pid_thr.reset()
        self._pid_fb_bbox.reset()
        self._pid_fb_tof.reset()
        self._pitch_source_last = 'none'
        self.front_tof_cm = -1.0
        self._tof_ema     = -1.0
        self._follow_status = 'waiting'
        self._tof_display   = -1.0
        with self._rc_lock:
            self._rc = [0, 0, 0, 0]
        with self._frame_lock:
            self._debug_frame = None


_follow_ctrl: FollowController = None

# ============================================================
# ORBIT
# ============================================================

def _run_orbit(radius_cm: int, clockwise: bool):
    global _orbit_active
    yaw_speed = 30
    fwd_speed = 20
    if not clockwise:
        yaw_speed = -yaw_speed
    try:
        interval = 1.0 / 20.0
        while _orbit_active:
            if tello is None or tello.state != 'flying':
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

def on_connect(client,userdata, flags_dict, rc):
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
            print(f'Error enviando telemetrí­a: {e}')


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
            if tello is None:  return
            if _follow_mode:   return
            if _orbit_active:  return
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


def on_message(client,userdata, message):
    global _pc, _camera_track, flight_mode, camera_index, _follow_mode, tello, _follow_ctrl
    global _orbit_active, _orbit_thread

    parts   = message.topic.split('/')
    command = parts[2]
    print(f'Comando recibido: {command}')

    if command == 'setMode':
        mode = message.payload.decode().strip()
        if mode in ('ardupilot', 'sitl', 'tello'):
            flight_mode = mode
            if mode == 'tello' and tello is None:
                tello = TelloDron()
            print(f'[CONFIG] Modo de vuelo: {flight_mode}')
        else:
            print(f'[WARN] Modo desconocido: {mode}')

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
                    try: asyncio.run_coroutine_threadsafe(_pc.close(), loop)
                    except Exception: pass
                    _pc = None; _camera_track = None; telemetry_channel = None
                client.publish('groundStation/mobileFlutter/connected', 'connected')
                time.sleep(0.3)
                if tello.state == 'flying':
                    client.publish('groundStation/mobileFlutter/flying', 'flying')
                asyncio.run_coroutine_threadsafe(webrtc_client(), loop)
                return

            conn_str = 'com7' if flight_mode == 'ardupilot' else 'tcp:127.0.0.1:5763'
            baud     = 57600  if flight_mode == 'ardupilot' else 115200
            already  = dron.state in ('connected', 'armed', 'flying', 'returning')
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

    if command == 'arm':
        if flight_mode == 'tello': return
        if dron.state == 'connected':
            def armar():
                dron.arm()
                client.publish('groundStation/mobileFlutter/armed', 'armed')
                threading.Thread(target=monitor_arm_state, daemon=True).start()
            threading.Thread(target=armar).start()

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
            parts_p  = message.payload.decode().split(':')
            altitude = int(parts_p[0])
            speed    = float(parts_p[1]) if len(parts_p) > 1 else dron.navSpeed
            def despegar():
                dron.navSpeed = speed; dron.takeOff(altitude)
                dron.vehicle.set_mode('LOITER'); dron.changeNavSpeed(speed)
                client.publish('groundStation/mobileFlutter/flying', 'flying')
            threading.Thread(target=despegar).start()

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

    if command == 'rtl':
        if flight_mode == 'tello': return
        if dron.state in ('flying', 'returning'):
            def rtl():
                dron.changeNavSpeed(dron.navSpeed); dron.RTL()
                client.publish('groundStation/mobileFlutter/landed', 'landed')
            threading.Thread(target=rtl).start()

    if command == 'speed':
        if flight_mode == 'tello': return
        spd = float(message.payload.decode())
        dron.navSpeed = spd
        if dron.vehicle: dron.changeNavSpeed(spd)

    if command == 'zoom':
        try:
            zoom_val = max(1.0, min(float(message.payload.decode()), 10.0))
            if _camera_track: _camera_track.zoom_factor = zoom_val
        except ValueError:
            print('[WARN] Zoom: valor invalido')

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

        if command == 'orbit':
            global _orbit_active, _orbit_thread
            if flight_mode == 'tello' and tello and tello.state == 'flying':
                payload = message.payload.decode().strip()
                if payload == 'stop':
                    _orbit_active = False
                elif not _orbit_active:
                    # Desactivar follow mode si está activo
                    if _follow_mode:
                        _follow_mode = False
                        if _follow_ctrl:
                            _follow_ctrl.stop()

                    parts_o   = payload.split(':')
                    radius_cm = int(parts_o[0])
                    clockwise = len(parts_o) > 1 and parts_o[1] == 'cw'
                    _orbit_active = True
                    _orbit_thread = threading.Thread(
                        target=_run_orbit,
                        args=(radius_cm, clockwise),
                        daemon=True
                    )
                    _orbit_thread.start()

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
                            target=_follow_ctrl._rc_loop, daemon=True)
                        _follow_ctrl._rc_thread.start()
                    if not _follow_ctrl._vid_thread.is_alive():
                        _follow_ctrl._vid_thread = threading.Thread(
                            target=_follow_ctrl._video_loop, daemon=True)
                        _follow_ctrl._vid_thread.start()
                print('[TELLO] Follow mode ACTIVADO')
            else:
                if _follow_ctrl: _follow_ctrl.stop()
                print('[TELLO] Follow mode DESACTIVADO')

    if command == 'detectionMode':
        mode = message.payload.decode()
        if _camera_track:
            _camera_track.detection_mode = mode
            _camera_track.detecciones    = []

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
            global _pc, _camera_track
            try: dron.stop_sending_telemetry_info()
            except Exception: pass
            dron.disconnect()
            if _pc:
                try: asyncio.run_coroutine_threadsafe(_pc.close(), loop)
                except Exception as e: print(f'Error cerrando PC: {e}')
            _pc = None; _camera_track = None
            client.publish('groundStation/mobileFlutter/disconnected', 'disconnected')
        threading.Thread(target=desconectar).start()

    if command == 'uploadMission':
        global _pending_mission, _pending_actions
        try:
            data        = json.loads(message.payload.decode())
            wp_data     = data.get('waypoints', [])
            takeoff_alt = data.get('takeoffAlt', 5)
            speed       = data.get('speed', dron.navSpeed)
            dronlink_wp = []
            actions     = []
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
                        action      = _pending_actions[index]
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
            if _follow_mode and _follow_ctrl is not None and tello.state == 'flying':
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
    global _pc, telemetry_channel, _camera_track, _webrtc_running

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
    ssl_ctx.verify_mode    = ssl.CERT_NONE

    try:
        async with websockets.connect(SIGNAL_URL, ssl=ssl_ctx) as ws:
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
            joystick_channel  = _pc.createDataChannel('joystick')
            telemetry_channel = _pc.createDataChannel('telemetry')

            @joystick_channel.on('message')
            def on_joystick(msg): handle_joystick(msg)

            @_pc.on('icecandidate')
            async def on_ice(candidate):
                payload = {
                    'target': REMOTE_ID, 'type': 'candidate',
                    'candidate': {
                        'candidate':     candidate.candidate,
                        'sdpMid':        candidate.sdpMid,
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
                'offer': {'sdp':  _pc.localDescription.sdp,
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
                        rc.sdpMid        = cand.get('sdpMid') or '0'
                        rc.sdpMLineIndex = cand.get('sdpMLineIndex') or 0
                        await _pc.addIceCandidate(rc)
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
dron.navSpeed  = 3.0
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