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
import websockets
from aiortc import RTCPeerConnection, RTCSessionDescription, VideoStreamTrack
from aiortc.sdp import candidate_from_sdp
from av import VideoFrame
import torch

from dronLink.Dron import Dron


# ============================================================
# CONSTANTES
# ============================================================

BROKER     = 'broker.hivemq.com'
PORT_MQTT  = 1883
SIGNAL_URL = 'wss://dronseetac.upc.edu:8104/ws'

MY_ID      = 'python'   # identificador de esta ET 
REMOTE_ID  = 'browser'  # identificador del cliente Flutter

_monitoring       = False
_pc               = None
telemetry_channel = None
_camera_track     = None  

# Modelo YOLOv5s 
model = torch.hub.load('ultralytics/yolov5', 'yolov5s', pretrained=True)
model.eval()

# El loop corre en un thread separado para que las corrutinas WebRTC
# no bloqueen el loop MQTT principal (que corre en el hilo principal).
loop = asyncio.new_event_loop()

def _start_loop(lp: asyncio.AbstractEventLoop):
    asyncio.set_event_loop(lp)
    lp.run_forever()

_loop_thread = threading.Thread(target=_start_loop, args=(loop,), daemon=True)
_loop_thread.start()


# ============================================================
# MQTT
# ============================================================

def on_connect(client, userdata, flags, rc):
    if rc == 0:
        print('Ground Station connected :)')
        client.subscribe('mobileFlutter/groundStation/#')   #suscripción mqtt
        print('Waiting for topics...')
    else:
        print(f'Error connecting the broker, code: {rc}')


# Envía el JSON de telemetría al navegador via DataChannel WebRTC.
def process_telemetry_info(telemetry_info):
    global telemetry_channel
    payload = json.dumps(telemetry_info)
    if telemetry_channel is not None and telemetry_channel.readyState == 'open':
        try:
            loop.call_soon_threadsafe(telemetry_channel.send, payload)
        except Exception as e:
            print(f'Error enviando telemetria por WebRTC: {e}')


# Monitoriza el estado de armado en un thread separado.
# Cuando el dron se desarma solo (p.ej. failsafe), notifica a Flutter via MQTT.
def monitor_arm_state():
    global _monitoring
    if _monitoring:
        return
    _monitoring = True
    time.sleep(1)

    while True:
        if dron.vehicle is not None:
            armed = dron.vehicle.motors_armed()
            if not armed:
                client.publish('groundStation/mobileFlutter/disarmed', 'disarmed')
                break
        else:
            break
        time.sleep(1)

    _monitoring = False


# Despacha los comandos MQTT recibidos desde Flutter.
# Convención de topics: mobileFlutter/groundStation/<command>

#COMANDOS 
def on_message(client, userdata, message):
    global _pc, _camera_track
    parts   = message.topic.split('/')
    command = parts[2]
    print(f'Command: {command}')

    if command == 'connect':
        # Conecta al dron via MAVLink y lanza el cliente WebRTC
        def conectar():
            print('Connecting to the drone...')
            dron.connect('tcp:127.0.0.1:5763', 115200)
            print('Drone connected!')
            dron.frequency = 2
            dron.send_telemetry_info(process_telemetry_info)
            client.publish('groundStation/mobileFlutter/connected', 'connected')
            asyncio.run_coroutine_threadsafe(webrtc_client(), loop)
        threading.Thread(target=conectar).start()

    if command == 'arm':
        if dron.state == 'connected':
            def armar():
                dron.arm()
                print('Motors armed!')
                client.publish('groundStation/mobileFlutter/armed', 'armed')
                threading.Thread(target=monitor_arm_state, daemon=True).start()
            threading.Thread(target=armar).start()
        else:
            print(f'Arm ignorado: estado del dron es "{dron.state}"')

    if command == 'takeoff':
        if dron.state in ('armed', 'flying'):
            altitude = int(message.payload.decode())
            def despegar():
                print(f'Taking off to {altitude}m...')
                dron.takeOff(altitude)
                print('Takeoff complete!')
                dron.vehicle.set_mode('ALT_HOLD')  # ALT_HOLD para control de altitud manual
                client.publish('groundStation/mobileFlutter/flying', 'flying')
            threading.Thread(target=despegar).start()
        else:
            print(f'Not able to take off, dron state: {dron.state}')

    if command == 'land':
        if dron.state in ('flying', 'returning'):
            def aterrizar():
                print('Landing...')
                dron.Land()
                print('Landed!')
                client.publish('groundStation/mobileFlutter/landed', 'landed')
            threading.Thread(target=aterrizar).start()
        else:
            print(f'Not able to land. State: "{dron.state}"')

    if command == 'rtl':
        if dron.state in ('flying', 'returning'):
            def rtl():
                print('Returning to launch...')
                dron.RTL()
                print('RTL complete!')
                client.publish('groundStation/mobileFlutter/landed', 'landed')
            threading.Thread(target=rtl).start()
        else:
            print(f'Not able to RTL. State: "{dron.state}"')

    if command == 'speed':
        spd = float(message.payload.decode())
        def set_speed():
            print(f'Setting flight speed to {spd} m/s...')
            dron.navSpeed = spd
            dron.changeNavSpeed(spd)
        threading.Thread(target=set_speed).start()

    if command == 'detectionMode':
        # Cambia el modo de detección YOLO en caliente sin reiniciar el track
        mode = message.payload.decode()  # 'all' | 'person' | 'none'
        if _camera_track is not None:
            _camera_track.detection_mode = mode
            _camera_track.detecciones    = []  # limpiar bboxes anteriores
        print(f'Modo de deteccion: {mode}')

    if command == 'disconnect':
        def desconectar():
            global _pc, _camera_track
            print('Disconnecting drone...')
            try:
                dron.stop_sending_telemetry_info()
            except Exception:
                pass

            dron.disconnect()

            # Cierra el PeerConnection WebRTC desde el loop asyncio
            if _pc is not None:
                try:
                    asyncio.run_coroutine_threadsafe(_pc.close(), loop)
                except Exception as e:
                    print(f'Error cerrando PeerConnection: {e}')
                _pc = None

            _camera_track = None
            print('Drone disconnected!')
            client.publish('groundStation/mobileFlutter/disconnected', 'disconnected')

        threading.Thread(target=desconectar).start()


# ============================================================
# WEBRTC — Video Track con YOLO
# ============================================================

class CameraVideoTrack(VideoStreamTrack):
    def __init__(self):
        super().__init__()
        print('Preparando camara...')
        self.cap            = cv2.VideoCapture(0)
        self.frame_count    = 0
        self.detecciones    = []        # lista de boxes del último frame procesado
        self.detection_mode = 'all'    # 'all' | 'person' | 'none'

    async def recv(self):
        self.frame_count += 1
        ret, frame = self.cap.read()
        if not ret:
            return None

        # Inferencia YOLO cada 25 frames 
        if self.frame_count % 25 == 0 and self.detection_mode != 'none':
            img_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            results = model(img_rgb)
            self.detecciones = []
            for *box, conf, cls in results.xyxy[0]:
                x1, y1, x2, y2 = map(int, box)
                label           = model.names[int(cls.item())]
                confidence      = float(conf.item())
                # En modo 'person' descartar todo lo que no sea persona
                if self.detection_mode == 'person' and label != 'person':
                    continue
                self.detecciones.append((x1, y1, x2, y2, label, confidence))

        # Sin detecciones activas: limpiar boxes
        if self.detection_mode == 'none':
            self.detecciones = []

        # Color de los boxes: verde para 'all', naranja para 'person'
        color = (0, 255, 0) if self.detection_mode == 'all' else (0, 150, 255)
        for (x1, y1, x2, y2, label, confidence) in self.detecciones:
            text = f'{label} ({confidence*100:.0f}%)'
            cv2.rectangle(frame, (x1, y1), (x2, y2), color, 2)
            cv2.putText(frame, text, (x1, y1 - 10),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.6, color, 2)

        # Hora actual 
        ts = datetime.now().strftime('%H:%M:%S.%f')[:-3]
        cv2.putText(frame, ts, (10, 30),
                    cv2.FONT_HERSHEY_SIMPLEX, 1, (0, 255, 0), 2)

        frame        = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        vf           = VideoFrame.from_ndarray(frame, format='rgb24')
        vf.pts       = self.frame_count
        vf.time_base = fractions.Fraction(1, 30)  # 30 fps
        return vf


# ============================================================
# JOYSTICK
# ============================================================

# Recibe el JSON de ejes del joystick desde el DataChannel WebRTC
# y lo convierte en señales RC PWM (1000–2000 µs) para el dron.
# Zona muerta de ±0.1 para evitar deriva en reposo.
def handle_joystick(data_str):
    try:
        data = json.loads(data_str)
        lx   = data.get('lx', 0.0)  # yaw
        ly   = data.get('ly', 0.0)  # throttle
        rx   = data.get('rx', 0.0)  # roll
        ry   = data.get('ry', 0.0)  # pitch

        if dron.state not in ('flying', 'returning'):
            return

        threshold = 0.1

        # Mapeo lineal: [-1, 1] - [1000, 2000] µs, neutro = 1500
        def to_pwm(val: float) -> int:
            return int(1500 + val * 500)

        roll     = to_pwm(rx) if abs(rx) >= threshold else 1500
        pitch    = to_pwm(ry) if abs(ry) >= threshold else 1500
        throttle = to_pwm(ly) if abs(ly) >= threshold else 1500
        yaw      = to_pwm(lx) if abs(lx) >= threshold else 1500

        dron.send_rc(roll, pitch, throttle, yaw)

    except Exception as e:
        print(f'Error joystick: {e}')


# ============================================================
# WEBRTC — cliente de señalización
# ============================================================

# Establece la conexión WebRTC con el navegador siguiendo el flujo:
#   1. Registra el peer_id en el servidor de señalización
#   2. Crea los DataChannels (joystick, telemetría)
#   3. Añade el VideoTrack de la cámara con detección YOLO
#   4. Envía la offer SDP y espera la answer de Flutter
#   5. Intercambia ICE candidates hasta completar el handshake
async def webrtc_client():
    global _pc, telemetry_channel, _camera_track

    ssl_context = ssl.create_default_context()
    ssl_context.check_hostname = False
    ssl_context.verify_mode    = ssl.CERT_NONE

    print(f'Conectando al servidor de senalizacion: {SIGNAL_URL}')

    try:
        async with websockets.connect(SIGNAL_URL, ssl=ssl_context) as ws:
            await ws.send(MY_ID)
            print(f'Identificado como "{MY_ID}", esperando a "{REMOTE_ID}"...')

            _pc = RTCPeerConnection()

            # DataChannel joystick: Python recibe los ejes desde Flutter
            joystick_channel = _pc.createDataChannel('joystick')

            @joystick_channel.on('message')
            def on_joystick(message):
                handle_joystick(message)

            # DataChannel telemetría: Python envía el JSON de telemetría a Flutter
            telemetry_channel = _pc.createDataChannel('telemetry')

            @_pc.on('icecandidate')
            async def on_ice(candidate):
                if candidate:
                    await ws.send(json.dumps({
                        'target':    REMOTE_ID,
                        'type':      'candidate',
                        'candidate': {
                            'candidate':     candidate.candidate,
                            'sdpMid':        candidate.sdpMid,
                            'sdpMLineIndex': candidate.sdpMLineIndex,
                        },
                    }))
                else:
                    # None indica fin de candidatos ICE
                    await ws.send(json.dumps({
                        'target':    REMOTE_ID,
                        'type':      'candidate',
                        'candidate': None,
                    }))

            # Crea el track, guarda referencia global y lo añade al PeerConnection
            track         = CameraVideoTrack()
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

            # Bucle de mensajes de señalización hasta cerrar la conexión
            async for raw in ws:
                data = json.loads(raw)

                if data.get('type') == 'answer':
                    answer = data['answer']
                    await _pc.setRemoteDescription(
                        RTCSessionDescription(
                            sdp=answer['sdp'],
                            type=answer['type'],
                        )
                    )
                    print('WebRTC handshake completo')

                if data.get('type') == 'candidate':
                    cand = data.get('candidate')
                    if cand is None:
                        continue
                    try:
                        rtc_cand               = candidate_from_sdp(cand['candidate'])
                        rtc_cand.sdpMid        = cand.get('sdpMid') or '0'
                        rtc_cand.sdpMLineIndex = cand.get('sdpMLineIndex') or 0
                        await _pc.addIceCandidate(rtc_cand)
                    except Exception as e:
                        print(f'Error anadiendo ICE candidate: {e}')

    except Exception as e:
        print(f'Error en webrtc_client: {e}')


# ============================================================
# ARRANQUE
# ============================================================

dron          = Dron()
dron.navSpeed = 2.0 # Velocidad de navegación por defecto

# Client ID aleatorio para evitar colisiones en el broker MQTT
client_name = 'groundStation' + str(random.randint(1000, 9000))
client      = mqtt.Client(client_name)
client.on_connect = on_connect
client.on_message = on_message

print(f'Connecting to broker {BROKER}:{PORT_MQTT}...')
client.connect(BROKER, PORT_MQTT)
client.loop_start()

print('Sistema listo. Esperando comandos MQTT...')
threading.Event().wait()  # bloquea el hilo principal indefinidamente