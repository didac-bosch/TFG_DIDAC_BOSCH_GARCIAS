import paho.mqtt.client as mqtt
import random
import threading
import time
import json
import asyncio
import fractions
import ssl
from concurrent.futures import ThreadPoolExecutor
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

# --- Suavizado del joystick (Tello) ---
MANUAL_DEADZONE = 0.1        # zona muerta del stick
MANUAL_EXPO = 1.5            # curva expo (suaviza la zona central)
MANUAL_MAX_SPEED_PCT = 0.6   # tope de velocidad: fondo de escala = 60 (de 100)

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
_panorama_ctrl = None
_panorama_active = False
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

# modelo yolo para tello (detecta poses + follow/orbit con re-ID)
# Antes era 'yolov8n-pose.onnx' (onnxruntime, por defecto CPU, nano, imgsz 320).
# En el portatil con RTX 5060 usamos el modelo PyTorch grande SOBRE GPU: keypoints
# mas fiables, deteccion de personas mas lejanas y tracker BoT-SORT (re-ID) en
# follow_controller. POSE_MODEL_NAME y POSE_IMGSZ centralizan el tuneo de banco.
from ultralytics import YOLO
POSE_MODEL_NAME = 'yolo11m-pose.pt'   # banco: 'yolo11l-pose.pt' si sobra margen GPU
POSE_IMGSZ      = 640                 # debe coincidir con follow_controller.POSE_IMGSZ
pose_model = YOLO(POSE_MODEL_NAME)
if DEVICE == 'cuda':
    pose_model.to('cuda')
print(f'[INFO] pose_model ({POSE_MODEL_NAME}) en {DEVICE}')
# Warmup: construir el grafo y el primer forward AHORA (al abrir la ET), no en la
# primera deteccion de Follow/Orbit. Mismo imgsz que _detect_persons.
try:
    pose_model(np.zeros((POSE_IMGSZ, POSE_IMGSZ, 3), dtype=np.uint8),
               imgsz=POSE_IMGSZ, verbose=False)
    print('[INFO] pose_model (follow/orbit) warmup OK')
except Exception as e:
    print(f'[WARN] pose_model warmup fallo: {e}')

# ============================================================
# LOOP ASYNCIO
# ============================================================

loop = asyncio.new_event_loop()

# Executor dedicado para producir/procesar los frames de vídeo (captura + YOLO)
# fuera del event loop, de modo que los envíos de telemetría no queden atascados
# detrás del cómputo de vídeo. Un solo worker: aiortc espera a recv() antes de
# volver a llamarlo, así que nunca hay dos frames en vuelo a la vez.
_video_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix='video')

def _start_loop(lp):
    asyncio.set_event_loop(lp)
    lp.run_forever()

threading.Thread(target=_start_loop, args=(loop,), daemon=True).start()

# ============================================================
# FOLLOW CONTROLLER
# El import se realiza AQUI, despues de que pose_model este definido.
# pose_model se INYECTA al construir FollowController (no se importa desde
# dentro): la ET corre como __main__, así que `from estacion_tierra import
# pose_model` re-ejecutaría todo el fichero y colgaría en su
# `threading.Event().wait()` final.
# ============================================================

from follow_controller import FollowController
from panorama_controller import PanoramaController

_follow_ctrl: FollowController = None

def _on_follow_stream_dead():
    """Callback invocado por FollowController cuando el stream de vídeo muere.
    Resetea los globals de follow/orbit para que la telemetría refleje 'off'."""
    global _follow_mode, _orbit_active, _follow_ctrl
    print('[FOLLOW] Stream muerto — reseteando estado follow/orbit')
    _follow_mode = False
    _orbit_active = False
    _follow_ctrl = None

# --- Callbacks del modo Panorama 360 (invocados desde el hilo del controller) ---
def _pub_panorama_status(status):
    """Publica el estado del escaneo hacia Flutter. En estados terminales que no
    sean 'done' (el 'done' lo cierra _on_panorama_done al entregar la imagen)
    libera el flag de modo activo."""
    global _panorama_active
    client.publish('groundStation/mobileFlutter/panoramaStatus', status)
    if status in ('error', 'off'):
        _panorama_active = False

def _on_panorama_done(b64):
    """Entrega la panorámica final (base64) a Flutter para que la guarde en la
    galería, y cierra el modo."""
    global _panorama_active, _panorama_ctrl
    client.publish('groundStation/mobileFlutter/panoramaReady', b64)
    _panorama_active = False
    _panorama_ctrl = None

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
            # Snapshot local: on_message (hilo MQTT) puede poner _follow_ctrl=None
            # entre la comprobación del `and` y el acceso al atributo → el GIL no
            # previene este TOCTOU. Capturar la referencia una vez.
            ctrl = _follow_ctrl
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
                'followStatus': ctrl._follow_status if (ctrl and _follow_mode) else 'off',
                'tofDistance': ctrl._tof_display if (ctrl and _follow_mode) else -1.0,
                'orbitStatus': ctrl._orbit_status if (ctrl and ctrl._orbit_mode) else 'off',
                'orbitTofDistance': ctrl._orbit_tof_display if (ctrl and ctrl._orbit_mode) else -1.0,
                'telloWifi': getattr(tello, 'wifi', None),
                'telloTempC': getattr(tello, 'temp_c', None),
                'telloFlightTime': getattr(tello, 'flight_time_s', None),
            })
            if telemetry_channel is not None and telemetry_channel.readyState == 'open':
                loop.call_soon_threadsafe(telemetry_channel.send, payload)
        except Exception as e:
            print(f'[TELLO TELEMETRY] Error: {e}')
        time.sleep(0.2)

def monitor_arm_state():
    global _monitoring
    if _monitoring:
        return
    _monitoring = True
    # Esperar hasta que los motores estén efectivamente armados (máx. 10 s)
    # antes de empezar a monitorizar el desarmado. Sin esta espera, la primera
    # comprobación (a 1 s del comando arm) puede pillar al dron aún sin armar
    # y publicar 'disarmed' espurio.
    for _ in range(10):
        if dron.vehicle is None:
            _monitoring = False
            return
        if dron.vehicle.motors_armed():
            break
        time.sleep(1)
    else:
        # El dron no llegó a armarse en 10 s — no publicar nada
        _monitoring = False
        return
    # Ahora sí: vigilar que no se desarme inesperadamente
    for _ in range(300):
        if dron.vehicle is None:
            break
        if not dron.vehicle.motors_armed():
            client.publish('groundStation/mobileFlutter/disarmed', 'disarmed')
            break
        time.sleep(1)
    _monitoring = False

def _axis_to_rc(v):
    """Convierte un eje del stick (-1..1) a velocidad RC (-60..60) con zona
    muerta + curva expo + tope de velocidad, para un control suave."""
    if abs(v) < MANUAL_DEADZONE:
        return 0
    sign = 1 if v >= 0 else -1
    # expo: suaviza la zona central sin perder el fondo de escala
    shaped = sign * (abs(v) ** MANUAL_EXPO)
    rc = int(shaped * 100 * MANUAL_MAX_SPEED_PCT)
    limit = int(100 * MANUAL_MAX_SPEED_PCT)
    return max(-limit, min(limit, rc))


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
            if _panorama_active: return
            if tello.state != 'flying': return
            # Envío directo en cada mensaje: al soltar el stick los ejes quedan
            # bajo la zona muerta -> _axis_to_rc devuelve 0 -> se manda rc(0,0,0,0).
            tello.rc(
                _axis_to_rc(rx),   # vx (izq/der)
                _axis_to_rc(ry),   # vy (adelante/atrás)
                _axis_to_rc(ly),   # vz (arriba/abajo)
                _axis_to_rc(lx),   # yaw (rotación)
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

def on_message(client, userdata, message):
    global _pc, _camera_track, flight_mode, camera_index, _follow_mode, tello, _follow_ctrl
    global _orbit_active, _orbit_thread, _panorama_ctrl, _panorama_active

    parts = message.topic.split('/')
    command = parts[2] if len(parts) > 2 else "PARTS ERROR"
    print(f'Comando recibido: {command}, payload = {message.payload.decode()}')

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
                    fut = asyncio.run_coroutine_threadsafe(_pc.close(), loop)
                    fut.result(timeout=3)
                    _pc = None; _camera_track = None; telemetry_channel = None
                client.publish('groundStation/mobileFlutter/connected', 'connected')
                time.sleep(0.3)
                if tello.state == 'flying':
                    client.publish('groundStation/mobileFlutter/flying', 'flying')
                asyncio.run_coroutine_threadsafe(webrtc_client(), loop)
                return

            conn_str = 'com3' if flight_mode == 'ardupilot' else 'tcp:127.0.0.1:5763'
            baud = 57600 if flight_mode == 'ardupilot' else 115200
            already = dron.state in ('connected', 'armed', 'flying', 'returning')
            if already and hasattr(dron, '_conn_str') and dron._conn_str != conn_str:
                already = False
                try: dron.stop_sending_telemetry_info(); dron.disconnect()
                except Exception: pass
            if not already:
                try:
                    dron.connect(conn_str, baud, freq=10); dron._conn_str = conn_str
                    if dron.vehicle is None: raise Exception('Vehicle is None')
                    dron.frequency = 10
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
            try:
                parts_p = message.payload.decode().split(':')
                altitude = int(parts_p[0])
                speed = float(parts_p[1]) if len(parts_p) > 1 else dron.navSpeed
            except (ValueError, IndexError) as e:
                print(f'[TAKEOFF] payload inválido: {e}')
                return
            def despegar():
                dron.navSpeed = speed; dron.takeOff(altitude)
                dron.vehicle.set_mode('LOITER'); dron.changeNavSpeed(speed)
                client.publish('groundStation/mobileFlutter/flying', 'flying')
            threading.Thread(target=despegar).start()

    if command == 'land':
        if flight_mode == 'tello':
            if tello is None: return
            if tello.state == 'flying':
                # Detener Follow Y Orbit antes de aterrizar: si seguimos en
                # cualquiera de los dos modos, su FSM sigue enviando RC y puede
                # mantener el dron en el aire. Replica la lógica de orbit 'stop'.
                if _follow_mode:
                    _follow_mode = False
                if _follow_ctrl is not None:
                    if getattr(_follow_ctrl, '_orbit_mode', False):
                        _follow_ctrl.deactivate_orbit()
                    _follow_ctrl.stop()
                    _follow_ctrl = None
                _orbit_active = False
                if _orbit_thread and _orbit_thread.is_alive():
                    _orbit_thread.join(timeout=0.3)
                # Parar tambien un escaneo Panorama en curso antes de aterrizar.
                if _panorama_ctrl is not None:
                    try: _panorama_ctrl.stop()
                    except Exception: pass
                    _panorama_ctrl = None
                _panorama_active = False
                def aterrizar_tello():
                    # Solo confirmamos 'landed' si el descenso se confirma por
                    # altura. Si no, reafirmamos 'flying' para que la UI mantenga
                    # isFlying=true y el botón LAND (el dron sigue en el aire).
                    try:
                        ok = tello.Land(blocking=True)
                    except Exception as e:
                        print(f'[LAND] Excepción al aterrizar Tello: {e}')
                        ok = False
                    if ok:
                        client.publish('groundStation/mobileFlutter/landed', 'landed')
                    else:
                        print('[LAND] Aterrizaje NO confirmado; reafirmo flying.')
                        client.publish('groundStation/mobileFlutter/flying', 'flying')
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
        try:
            spd = float(message.payload.decode())
        except ValueError as e:
            print(f'[SPEED] payload inválido: {e}')
            return
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
            # El firmware del Tello rechaza el flip con bateria < ~50% (responde
            # 'error' tras 4 reintentos del SDK). Comprobar antes y avisar a Flutter
            # en vez de intentarlo y fallar en silencio.
            batt = getattr(tello, 'battery_pct', None)
            if batt is not None and batt < 50:
                msg = f'Bateria baja ({batt}%): flip no permitido'
                print(f'[TELLO] {msg}')
                client.publish('groundStation/mobileFlutter/flipStatus', msg)
            else:
                # flip es un comando con respuesta: serializar con el lock unico del
                # Tello para no cruzar respuestas con telemetría/tof/stream.
                with tello._sdk_lock:
                    try:
                        tello._tello.flip(d[0])
                    except Exception as e:
                        print(f'[TELLO] Flip error: {e}')
                        client.publish('groundStation/mobileFlutter/flipStatus',
                                       'Flip rechazado por el dron')

    if command == 'orbit':
        if flight_mode == 'tello' and tello and tello.state == 'flying':
            payload_str = message.payload.decode().strip()

            if payload_str == 'stop':
                print('[ORBIT] STOP recibido')
                if _follow_ctrl is not None:
                    if _follow_ctrl._orbit_mode:
                        _follow_ctrl.deactivate_orbit()
                    _follow_ctrl.stop()
                    _follow_ctrl = None
                _orbit_active = False
                if _orbit_thread and _orbit_thread.is_alive():
                    _orbit_thread.join(timeout=0.3)
                client.publish('groundStation/mobileFlutter/orbitStatus', 'off')

            else:
                # Radio automático: ya NO se usa el valor del slider. El Orbit captura
                # la distancia actual a la persona como radio (ver activate_orbit). Solo
                # se parsea la dirección. Compat: tolera tanto 'cw'/'ccw' como el formato
                # antiguo '<n>:cw' (el número se ignora).
                clockwise = 'ccw' not in payload_str.lower()

                if _follow_mode:
                    print('[ORBIT] Follow activo — reiniciando como Orbit')
                    _follow_mode = False
                    client.publish('groundStation/mobileFlutter/followModeStatus', 'off')

                # Construir un FollowController fresco (hilos nuevos) para evitar
                # hilos zombi de una sesión Follow/Orbit anterior. Envuelto en
                # try/except: un fallo al crear/activar no debe matar on_message.
                try:
                    if _follow_ctrl is not None:
                        _follow_ctrl.stop()
                    _follow_ctrl = FollowController(tello, pose_model=pose_model)
                    _follow_ctrl.on_stream_dead = _on_follow_stream_dead

                    _follow_ctrl.activate_orbit(clockwise=clockwise)
                    _orbit_active = True
                    print(f'[ORBIT] Lanzado — radio=auto (distancia actual), cw={clockwise}')
                    client.publish('groundStation/mobileFlutter/orbitStatus', 'on')
                except Exception as e:
                    print(f'[ORBIT] Error al lanzar: {e}')
                    _orbit_active = False
                    if _follow_ctrl is not None:
                        try: _follow_ctrl.stop()
                        except Exception: pass
                        _follow_ctrl = None
                    client.publish('groundStation/mobileFlutter/orbitStatus', 'off')
        else:
            # Precondición no cumplida (no Tello / no volando): rechazar y avisar
            # para que Flutter no quede con el flag de orbit puesto.
            print('[ORBIT] Rechazado — Tello no conectado o no volando')
            client.publish('groundStation/mobileFlutter/orbitStatus', 'off')

    if command == 'followMode':
        if flight_mode == 'tello' and tello is not None:
            new_state = message.payload.decode().strip() == 'true'
            if new_state == _follow_mode:
                return
            # Activar requiere dron volando (alinea con el handler 'orbit'); si no,
            # rechazar y avisar para que Flutter no deje el flag follow puesto.
            if new_state and tello.state != 'flying':
                print('[TELLO] Follow rechazado — dron no volando')
                client.publish('groundStation/mobileFlutter/followModeStatus', 'off')
                return
            if new_state:
                if _orbit_active:
                    _orbit_active = False
                    if _orbit_thread and _orbit_thread.is_alive():
                        _orbit_thread.join(timeout=0.5)
                    client.publish('groundStation/mobileFlutter/orbitStatus', 'off')
                # Construir un FollowController fresco (hilos nuevos) para evitar
                # hilos zombi de una sesión anterior que dejarían el modo atascado
                # en 'waiting'. Envuelto en try/except: un fallo no debe matar
                # on_message. El deactivate deja _follow_ctrl=None.
                try:
                    if _follow_ctrl is not None:
                        _follow_ctrl.stop()
                    _follow_ctrl = FollowController(tello, pose_model=pose_model)
                    _follow_ctrl.on_stream_dead = _on_follow_stream_dead
                    _follow_mode = True
                    print('[TELLO] Follow mode ACTIVADO')
                    client.publish('groundStation/mobileFlutter/followModeStatus', 'on')
                except Exception as e:
                    print(f'[TELLO] Error al activar Follow: {e}')
                    _follow_mode = False
                    if _follow_ctrl is not None:
                        try: _follow_ctrl.stop()
                        except Exception: pass
                        _follow_ctrl = None
                    client.publish('groundStation/mobileFlutter/followModeStatus', 'off')
            else:
                _follow_mode = False
                if _follow_ctrl:
                    _follow_ctrl.stop()
                    _follow_ctrl = None
                print('[TELLO] Follow mode DESACTIVADO')
                client.publish('groundStation/mobileFlutter/followModeStatus', 'off')

    if command == 'panorama360':
        if flight_mode == 'tello' and tello and tello.state == 'flying':
            payload_str = message.payload.decode().strip()

            if payload_str == 'stop':
                print('[PANORAMA] STOP recibido')
                if _panorama_ctrl is not None:
                    try: _panorama_ctrl.stop()
                    except Exception: pass
                    _panorama_ctrl = None
                _panorama_active = False
                client.publish('groundStation/mobileFlutter/panoramaStatus', 'off')

            else:
                # El escaneo gira el dron en sitio: es incompatible con Follow/Orbit
                # (que tambien mandan RC). Pararlos antes de arrancar.
                if _follow_mode:
                    _follow_mode = False
                    client.publish('groundStation/mobileFlutter/followModeStatus', 'off')
                if _orbit_active:
                    _orbit_active = False
                    client.publish('groundStation/mobileFlutter/orbitStatus', 'off')
                if _follow_ctrl is not None:
                    try: _follow_ctrl.stop()
                    except Exception: pass
                    _follow_ctrl = None

                # Construir un PanoramaController fresco. Envuelto en try/except:
                # un fallo al crear no debe matar on_message.
                try:
                    if _panorama_ctrl is not None:
                        _panorama_ctrl.stop()
                    _panorama_active = True
                    _panorama_ctrl = PanoramaController(
                        tello,
                        on_status=_pub_panorama_status,
                        on_done=_on_panorama_done,
                    )
                    print('[PANORAMA] Lanzado — escaneo 360 en la altitud actual')
                    client.publish('groundStation/mobileFlutter/panoramaStatus', 'scanning')
                except Exception as e:
                    print(f'[PANORAMA] Error al lanzar: {e}')
                    _panorama_active = False
                    if _panorama_ctrl is not None:
                        try: _panorama_ctrl.stop()
                        except Exception: pass
                        _panorama_ctrl = None
                    client.publish('groundStation/mobileFlutter/panoramaStatus', 'off')
        else:
            # Precondición no cumplida (no Tello / no volando): rechazar y avisar.
            print('[PANORAMA] Rechazado — Tello no conectado o no volando')
            client.publish('groundStation/mobileFlutter/panoramaStatus', 'off')

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
                global _orbit_active, _orbit_thread, _panorama_ctrl, _panorama_active
                if _panorama_ctrl is not None:
                    try: _panorama_ctrl.stop()
                    except Exception: pass
                    _panorama_ctrl = None
                _panorama_active = False
                _follow_mode = False
                # Resetear también orbit: sin esto, _orbit_active queda True y el
                # guard de handle_joystick bloquea el joystick tras reconectar
                # aunque no haya órbita real en curso.
                _orbit_active = False
                if _orbit_thread and _orbit_thread.is_alive():
                    _orbit_thread.join(timeout=0.5)
                _orbit_thread = None
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

    # Producción + procesado síncrono de un frame (captura, undistort, zoom,
    # detección YOLO y dibujado). Se ejecuta en un hilo worker (run_in_executor)
    # para NO bloquear el event loop de asyncio, que es por donde también se
    # envía la telemetría. cv2 y torch liberan el GIL en sus llamadas nativas,
    # así que el worker corre realmente en paralelo y el loop queda libre.
    def _build_frame(self):
        if flight_mode == 'tello':
            frame = tello.get_frame()
            if frame is None:
                frame = np.zeros((480, 640, 3), dtype=np.uint8)
            # djitellopy ya entrega RGB y el VideoFrame se emite como rgb24: no
            # convertir aquí (hacerlo intercambiaría R/B en el vídeo en vivo).
        else:
            ret, frame = self.cap.read()
            if not ret:
                frame = np.zeros((480, 640, 3), dtype=np.uint8)
            frame = self._undistort(frame)
            frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)

        frame = self._apply_zoom(frame)
        frame = cv2.resize(frame, (640, 480), interpolation=cv2.INTER_LINEAR)

        if flight_mode == 'tello':
            # Snapshot local: evita TOCTOU si on_message pone _follow_ctrl=None
            # entre la comprobación y get_debug_frame().
            ctrl = _follow_ctrl
            ctrl_active = ((_follow_mode or _orbit_active) and
                           ctrl is not None and
                           tello.state == 'flying')
            if ctrl_active:
                # Solo usar el debug frame si es reciente; si el follow loop se
                # retrasa/atasca, mostramos el frame en vivo (no se congela el stream).
                debug = ctrl.get_debug_frame(max_age_s=0.2)
                if debug is not None:
                    frame = debug
            return frame

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
            cv2.rectangle(frame_bgr, (x1, y1), (x2, y2), color, 2)
            cv2.putText(frame_bgr, f'{label} ({confidence*100:.0f}%)',
                        (x1, y1-10), cv2.FONT_HERSHEY_SIMPLEX, 0.6, color, 2)
        ts = datetime.now().strftime('%H:%M:%S.%f')[:-3]
        cv2.putText(frame_bgr, ts, (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 1, (0, 255, 0), 2)
        frame = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)
        return frame

    async def recv(self):
        self.frame_count += 1
        # El cómputo pesado (captura + YOLO) va a un hilo para liberar el event
        # loop; así los envíos de telemetría dejan de salir a ráfagas (~2.3 s) y
        # vuelven a su cadencia (~5 Hz).
        running_loop = asyncio.get_running_loop()
        frame = await running_loop.run_in_executor(_video_executor, self._build_frame)
        vf = VideoFrame.from_ndarray(frame, format='rgb24')
        vf.pts, vf.time_base = self.frame_count, fractions.Fraction(1, 30)
        # Pacing: cede el loop y acota a ~30 fps aunque _build_frame sea rápido.
        await asyncio.sleep(1 / 30)
        return vf

# ============================================================
# WEBRTC - señalización
# ============================================================

async def webrtc_client():
    global _pc, telemetry_channel, _camera_track, _webrtc_running, _ws

    if _webrtc_running:
        print('[WEBRTC] Sesión previa activa — cerrando antes de reconectar.')
        try:
            if _ws is not None: await _ws.close()
        except Exception: pass
        try:
            if _pc is not None: await _pc.close()
        except Exception: pass
        for _ in range(30):              # esperar máx 3s al finally previo
            if not _webrtc_running: break
            await asyncio.sleep(0.1)
        if _webrtc_running:
            print('[WEBRTC] Sesión previa no liberó el flag; abortando.')
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
