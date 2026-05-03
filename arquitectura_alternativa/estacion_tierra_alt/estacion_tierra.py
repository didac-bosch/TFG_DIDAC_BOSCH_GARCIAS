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

# ============================================================
# CONSTANTES
# ============================================================

BROKER      = 'broker.hivemq.com'
PORT_MQTT   = 1883
SIGNAL_URL  = 'wss://dronseetac.upc.edu:8105/ws'

MY_ID     = 'python'
REMOTE_ID = 'browser'

# ============================================================
# CONFIGURACIÓN DINÁMICA (se actualiza via MQTT desde Flutter)
# ============================================================

# Modo de vuelo: 'ardupilot' | 'sitl' | 'tello'
flight_mode = 'ardupilot'

# Índice de cámara: 0 (portátil) | 1 (dron)
camera_index = 1

# ============================================================
# ESTADO GLOBAL
# ============================================================

_monitoring       = False
_pc               = None
telemetry_channel = None
_camera_track     = None
_pending_mission = None
_pending_actions = []

# ============================================================
# CALIBRACIÓN CÁMARA (corrección ojo de pez)
# ============================================================

CALIB_FILE  = 'calibration_data_px.yaml'
cam_matrix  = None
dist_coefs  = None
new_cam_mtx = None
roi_crop    = None  # (x, y, w, h)

def load_calibration():
    global cam_matrix, dist_coefs, new_cam_mtx, roi_crop
    if not os.path.exists(CALIB_FILE):
        print(f'[WARN] "{CALIB_FILE}" no encontrado — corrección de lente desactivada.')
        return
    with open(CALIB_FILE) as f:
        data = yaml.safe_load(f)
    cam_matrix = np.array(data['camera_matrix'])
    dist_coefs = np.array(data['distortion_coefficients'])
    h, w = 480, 640
    new_cam_mtx, roi = cv2.getOptimalNewCameraMatrix(
        cam_matrix, dist_coefs, (w, h), 1, (w, h)
    )
    roi_crop = roi
    print(f'[INFO] Calibración cargada desde "{CALIB_FILE}"')

load_calibration()

# ============================================================
# MODELO YOLO
# ============================================================

model = torch.hub.load('ultralytics/yolov5', 'yolov5s', pretrained=True)
model.eval()

# ============================================================
# LOOP ASYNCIO (thread separado)
# ============================================================

loop = asyncio.new_event_loop()

def _start_loop(lp):
    asyncio.set_event_loop(lp)
    lp.run_forever()

threading.Thread(target=_start_loop, args=(loop,), daemon=True).start()

# ============================================================
# MQTT
# ============================================================

def on_connect(client, userdata, flags, rc):
    if rc == 0:
        print('Ground Station conectada :)')
        client.subscribe('mobileFlutter/groundStation/#')
        print('Esperando comandos...')
    else:
        print(f'Error conectando al broker, código: {rc}')


def process_telemetry_info(telemetry_info):
    global telemetry_channel
    payload = json.dumps(telemetry_info)
    if telemetry_channel is not None and telemetry_channel.readyState == 'open':
        try:
            loop.call_soon_threadsafe(telemetry_channel.send, payload)
        except Exception as e:
            print(f'Error enviando telemetría: {e}')


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


def on_message(client, userdata, message):
    global _pc, _camera_track, flight_mode, camera_index

    parts   = message.topic.split('/')
    command = parts[2]
    print(f'Comando recibido: {command}')

    # ── SET MODE (desde Flutter, antes de conectar) ───────────
    if command == 'setMode':
        mode = message.payload.decode().strip()
        if mode in ('ardupilot', 'sitl', 'tello'):
            flight_mode = mode
            print(f'[CONFIG] Modo de vuelo configurado: {flight_mode}')
        else:
            print(f'[WARN] Modo desconocido: {mode}')

    # ── SET CAMERA (desde Flutter, antes de conectar) ─────────
    if command == 'setCamera':
        try:
            idx = int(message.payload.decode().strip())
            if idx in (0, 1):
                camera_index = idx
                print(f'[CONFIG] Cámara configurada: {camera_index}')
                # Si ya hay un track activo, reinicia la captura
                if _camera_track is not None:
                    _camera_track.set_camera(camera_index)
            else:
                print(f'[WARN] Índice de cámara no válido: {idx}')
        except ValueError:
            print('[WARN] setCamera: valor no numérico')

    # ── CONNECT ───────────────────────────────────────────────
    if command == 'connect':
        def conectar():
            global _pc, _camera_track, telemetry_channel

            # Determinar cadena de conexión según modo
            if flight_mode == 'ardupilot':
                conn_str = 'com7'
                baud     = 57600
            elif flight_mode == 'sitl':
                baud = 115200
                conn_str = 'tcp:127.0.0.1:5763'
            else:  # tello — placeholder
                print('[ERROR] Modo "{flight_mode}"no disponible.')
                client.publish('groundStation/mobileFlutter/disconnected', f'mode_unavailable:{flight_mode}')
                return

            print(f'[INFO] Modo: {flight_mode} | Conexión: {conn_str} | Cámara: {camera_index}')

            already_connected = dron.state in ('connected', 'armed', 'flying', 'returning')

            # Determinar conn_str actual
            if flight_mode == 'ardupilot':
                target_conn = 'com7'
            else:
                target_conn = 'tcp:127.0.0.1:5763'

            # Si está conectado pero a otro endpoint, forzar reconexión
            if already_connected and hasattr(dron, '_conn_str') and dron._conn_str != target_conn:
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
                    dron._conn_str = conn_str   # guardar el endpoint activo
                    if dron.vehicle is None:
                        raise Exception('Vehicle is None after connect')
                    dron.frequency = 2
                    dron.send_telemetry_info(process_telemetry_info)
                except Exception as e:
                    print("Error al conectar")
                    client.publish('groundStation/mobileFlutter/disconnected', 'connection_failed')
                    return
            else:
                print(f'Recuperación de sesión — estado: "{dron.state}"')
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

    # ── ARM ───────────────────────────────────────────────────
    if command == 'arm':
        if dron.state == 'connected':
            def armar():
                dron.arm()
                print('Motores armados!')
                client.publish('groundStation/mobileFlutter/armed', 'armed')
                threading.Thread(target=monitor_arm_state, daemon=True).start()
            threading.Thread(target=armar).start()
        else:
            print(f'Arm ignorado: estado "{dron.state}"')

    # ── TAKEOFF ───────────────────────────────────────────────
    if command == 'takeoff':
        if dron.state in ('armed', 'flying'):
            parts_payload = message.payload.decode().split(':')
            altitude = int(parts_payload[0])
            speed    = float(parts_payload[1]) if len(parts_payload) > 1 else dron.navSpeed
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

    # ── LAND ──────────────────────────────────────────────────
    if command == 'land':
        if dron.state in ('flying', 'returning'):
            def aterrizar():
                print('Aterrizando...')
                dron.Land()
                print('Aterrizado!')
                client.publish('groundStation/mobileFlutter/landed', 'landed')
            threading.Thread(target=aterrizar).start()
        else:
            print(f'Land ignorado: estado "{dron.state}"')

    # ── RTL ───────────────────────────────────────────────────
    if command == 'rtl':
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

    # ── SPEED ─────────────────────────────────────────────────
    if command == 'speed':
        spd = float(message.payload.decode())
        print(f'Velocidad: {spd} m/s')
        dron.navSpeed = spd
        if dron.vehicle is not None:
            dron.changeNavSpeed(spd)

    # ── ZOOM ──────────────────────────────────────────────────
    if command == 'zoom':
        try:
            zoom_val = float(message.payload.decode())
            zoom_val = max(1.0, min(zoom_val, 10.0))
            if _camera_track is not None:
                _camera_track.zoom_factor = zoom_val
                print(f'Zoom: {zoom_val}x')
        except ValueError:
            print('[WARN] Zoom: valor inválido')

    # ── DETECTION MODE ────────────────────────────────────────
    if command == 'detectionMode':
        mode = message.payload.decode()
        if _camera_track is not None:
            _camera_track.detection_mode = mode
            _camera_track.detecciones    = []
        print(f'Modo detección YOLO: {mode}')

    # ── DISCONNECT ────────────────────────────────────────────
    if command == 'disconnect':
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
        
    # ── UPLOAD MISSION ────────────────────────────────────────
    if command == 'uploadMission':
        global _pending_mission, _pending_actions
        try:
            data       = json.loads(message.payload.decode())
            wp_data    = data.get('waypoints', [])
            takeoff_alt = data.get('takeoffAlt', 5)
            speed       = data.get('speed', dron.navSpeed)

            dronlink_waypoints = []
            actions            = []

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


    # ── START MISSION ─────────────────────────────────────────
    if command == 'startMission':
        if _pending_mission is None:
            print('[MISSION] No hay misión cargada')
            return

        def handle_waypoint(index, wp):
            """Callback ejecutado al llegar a cada waypoint."""
            client.publish('groundStation/mobileFlutter/missionWaypoint',str(index))
            if index >= len(_pending_actions):
                return
            action      = _pending_actions[index]
            action_type = action.get('type', 'none')
            action_secs = float(action.get('seconds', 5))

            if action_type == 'hover':
                print(f'[MISSION] WP {index+1}: hover {action_secs}s')
                time.sleep(action_secs)

            elif action_type == 'takePhoto':
                print(f'[MISSION] WP {index+1}: foto')
                client.publish('groundStation/mobileFlutter/cameraAction', 'photo')

            elif action_type == 'recordVideo':
                print(f'[MISSION] WP {index+1}: grabar {action_secs}s')
                client.publish(
                    'groundStation/mobileFlutter/cameraAction',
                    f'record:{int(action_secs)}'
                )
                time.sleep(action_secs)

         # ── START MISSION ─────────────────────────────────────────
    if command == 'startMission':
        if _pending_mission is None:
            print('[MISSION] No hay misión cargada')
            client.publish('groundStation/mobileFlutter/missionStarted', 'error')
            return

        def run_mission():
            print('[MISSION] Iniciando misión...')

            # 1. Publicamos missionStarted:ok ANTES del takeoff.
            #    Flutter tiene un timeout de 10s — si takeoff tarda más,
            #    Flutter cancela isMissionMode y el tracking desaparece.
            client.publish('groundStation/mobileFlutter/missionStarted', 'ok')

            try:
                # 2. Arm condicional: si viene de flight_screen ya está armado.
                #    Re-armar con motores activos provoca abort en ArduPilot.
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
                    client.publish(
                        'groundStation/mobileFlutter/missionWaypoint',
                        str(index)
                    )
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

                print('[MISSION] Misión completada — RTL automático')
                dron.RTL()
                client.publish('groundStation/mobileFlutter/landed', 'landed')

            except Exception as e:
                print(f'[MISSION ERROR] {e}')
                client.publish('groundStation/mobileFlutter/landed', 'landed')

        threading.Thread(target=run_mission, daemon=True).start()


# ============================================================
# WEBRTC — Video Track con corrección de lente + zoom + YOLO
# ============================================================

class CameraVideoTrack(VideoStreamTrack):
    def __init__(self, cam_idx: int = 1):
        super().__init__()
        self.zoom_factor    = 1.0
        self.detection_mode = 'all'
        self.detecciones    = []
        self.frame_count    = 0
        self.correct_lens   = cam_matrix is not None
        self.cap            = None
        self.set_camera(cam_idx)

    def set_camera(self, idx: int):
        """Cambia la fuente de vídeo en caliente."""
        if self.cap is not None:
            self.cap.release()
        print(f'[CAM] Abriendo cámara {idx}...')
        self.cap = cv2.VideoCapture(idx)
        if not self.cap.isOpened():
            print(f'[ERROR] No se pudo abrir la cámara {idx}')

    def _undistort(self, frame):
        if not self.correct_lens:
            return frame
        undistorted = cv2.undistort(frame, cam_matrix, dist_coefs, None, new_cam_mtx)
        x, y, w, h  = roi_crop
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
        ret, frame = self.cap.read()
        if not ret:
            frame = np.zeros((480, 640, 3), dtype=np.uint8)

        # 1. Corrección ojo de pez
        frame = self._undistort(frame)

        # 2. Zoom digital
        frame = self._apply_zoom(frame)

        # 3. Tamaño fijo 640×480
        frame = cv2.resize(frame, (640, 480), interpolation=cv2.INTER_LINEAR)

        # 4. YOLO cada 25 frames
        if self.frame_count % 25 == 0 and self.detection_mode != 'none':
            img_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            results = model(img_rgb)
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

        # 5. Dibujar bboxes
        color = (0, 255, 0) if self.detection_mode == 'all' else (0, 150, 255)
        for (x1, y1, x2, y2, label, confidence) in self.detecciones:
            text = f'{label} ({confidence * 100:.0f}%)'
            cv2.rectangle(frame, (x1, y1), (x2, y2), color, 2)
            cv2.putText(frame, text, (x1, y1 - 10),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.6, color, 2)

        # 6. Timestamp
        ts = datetime.now().strftime('%H:%M:%S.%f')[:-3]
        cv2.putText(frame, ts, (10, 30),
                    cv2.FONT_HERSHEY_SIMPLEX, 1, (0, 255, 0), 2)

        frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        vf           = VideoFrame.from_ndarray(frame, format='rgb24')
        vf.pts       = self.frame_count
        vf.time_base = fractions.Fraction(1, 30)
        return vf

# ============================================================
# JOYSTICK
# ============================================================

def handle_joystick(data_str):
    try:
        data = json.loads(data_str)
        lx   = data.get('lx', 0.0)
        ly   = data.get('ly', 0.0)
        rx   = data.get('rx', 0.0)
        ry   = data.get('ry', 0.0)

        if dron.state not in ('flying', 'returning'):
            return

        threshold = 0.1
        def to_pwm(val): return int(1500 + val * 500)
        
        yaw_expo = 0.4
        yaw_scale = 0.25
        def apply_expo(val,expo):return expo*val**3 + (1-expo)*val
        yaw_shaped = apply_expo(lx, yaw_expo)*yaw_scale

        roll     = to_pwm(rx) if abs(rx) >= threshold else 1500
        pitch    = to_pwm(ry) if abs(ry) >= threshold else 1500
        throttle = to_pwm(ly) if abs(ly) >= threshold else 1500
        yaw      = to_pwm(lx) if abs(lx) >= threshold else 1500

        dron.send_rc(roll, pitch, throttle, yaw)
    except Exception as e:
        print(f'Error joystick: {e}')

# ============================================================
# WEBRTC — señalización
# ============================================================

async def webrtc_client():
    global _pc, telemetry_channel, _camera_track

    ssl_ctx = ssl.create_default_context()
    ssl_ctx.check_hostname = False
    ssl_ctx.verify_mode    = ssl.CERT_NONE

    print(f'Conectando al servidor de señalización: {SIGNAL_URL}')

    try:
        async with websockets.connect(SIGNAL_URL, ssl=ssl_ctx) as ws:
            await ws.send(MY_ID)
            print(f'Identificado como "{MY_ID}", esperando a "{REMOTE_ID}"...')

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

            # Crear track con la cámara actualmente configurada
            track         = CameraVideoTrack(cam_idx=camera_index)
            _camera_track = track
            _pc.addTrack(track)

            offer = await _pc.createOffer()
            await _pc.setLocalDescription(offer)
            await ws.send(json.dumps({
                'target': REMOTE_ID,
                'type':   'offer',
                'offer':  {
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
                    print('WebRTC handshake completo ✓')

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

# ============================================================
# ARRANQUE
# ============================================================

dron          = Dron()
dron.navSpeed = 3.0
dron._conn_str = None

client_name = 'groundStation' + str(random.randint(1000, 9000))
client      = mqtt.Client(client_name)
client.on_connect = on_connect
client.on_message = on_message

print(f'Conectando al broker {BROKER}:{PORT_MQTT}...')
client.connect(BROKER, PORT_MQTT)
client.loop_start()

print('Sistema listo. Esperando comandos MQTT...')
threading.Event().wait()