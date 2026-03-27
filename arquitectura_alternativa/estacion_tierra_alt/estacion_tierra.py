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
SIGNAL_URL = 'wss://172.20.10.3:8443/ws'   #dominio!!!!!!!!!!

MY_ID      = 'python'
REMOTE_ID  = 'browser'

_monitoring       = False
_pc               = None
telemetry_channel = None

model = torch.hub.load('ultralytics/yolov5', 'yolov5s', pretrained=True)
model.eval()


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
        client.subscribe('mobileFlutter/groundStation/#')
        print('Waiting for topics...')
    else:
        print(f'Error connecting the broker, code: {rc}')


def process_telemetry_info(telemetry_info):
    """
    Telemetría SOLO por WebRTC DataChannel "telemetry".
    Se llama desde el thread de dronLink, por eso usamos
    call_soon_threadsafe para ejecutar el send dentro del
    loop asyncio y evitar "no current event loop in thread".
    """
    global telemetry_channel

    payload = json.dumps(telemetry_info)

    if telemetry_channel is not None and telemetry_channel.readyState == 'open':
        try:
            # call_soon_threadsafe es thread-safe y no necesita coroutine
            loop.call_soon_threadsafe(telemetry_channel.send, payload)
        except Exception as e:
            print(f'Error enviando telemetría por WebRTC: {e}')


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


def on_message(client, userdata, message):
    global _pc
    parts   = message.topic.split('/')
    command = parts[2]
    print(f'Command: {command}')

    if command == 'connect':
        def conectar():
            print('Connecting to the drone...')
            dron.connect('tcp:127.0.0.1:5763', 115200)
            print('Drone connected!')
            dron.frequency = 2
            dron.send_telemetry_info(process_telemetry_info)
            client.publish('groundStation/mobileFlutter/connected', 'connected')
            # run_coroutine_threadsafe: seguro desde cualquier thread, loop explícito
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
                dron.vehicle.set_mode('ALT_HOLD')
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

    if command == 'disconnect':
        def desconectar():
            global _pc
            print('Disconnecting drone...')
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

            print('Drone disconnected!')
            client.publish('groundStation/mobileFlutter/disconnected', 'disconnected')

        threading.Thread(target=desconectar).start()


# ============================================================
# WEBRTC — Video Track con YOLO
# ============================================================

class CameraVideoTrack(VideoStreamTrack):
    def __init__(self):
        super().__init__()
        print('Preparando cámara...')
        self.cap         = cv2.VideoCapture(0)
        self.frame_count = 0
        self.detecciones = []

    async def recv(self):
        self.frame_count += 1
        ret, frame = self.cap.read()
        if not ret:
            return None

        if self.frame_count % 25 == 0:
            img_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            results = model(img_rgb)
            self.detecciones = []
            for *box, conf, cls in results.xyxy[0]:
                x1, y1, x2, y2 = map(int, box)
                label           = model.names[int(cls.item())]
                confidence      = float(conf.item())
                self.detecciones.append((x1, y1, x2, y2, label, confidence))

        for (x1, y1, x2, y2, label, confidence) in self.detecciones:
            text = f'{label} ({confidence*100:.0f}%)'
            cv2.rectangle(frame, (x1, y1), (x2, y2), (0, 255, 0), 2)
            cv2.putText(frame, text, (x1, y1 - 10),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 0), 2)

        ts = datetime.now().strftime('%H:%M:%S.%f')[:-3]
        cv2.putText(frame, ts, (10, 30),
                    cv2.FONT_HERSHEY_SIMPLEX, 1, (0, 255, 0), 2)

        frame        = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
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

async def webrtc_client():
    global _pc, telemetry_channel

    ssl_context = ssl.create_default_context()
    ssl_context.check_hostname = False
    ssl_context.verify_mode    = ssl.CERT_NONE

    print(f'Conectando al servidor de señalización: {SIGNAL_URL}')

    try:
        async with websockets.connect(SIGNAL_URL, ssl=ssl_context) as ws:
            await ws.send(MY_ID)
            print(f'Identificado como "{MY_ID}", esperando a "{REMOTE_ID}"...')

            _pc = RTCPeerConnection()

            joystick_channel = _pc.createDataChannel('joystick')

            @joystick_channel.on('message')
            def on_joystick(message):
                handle_joystick(message)

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
                    await ws.send(json.dumps({
                        'target':    REMOTE_ID,
                        'type':      'candidate',
                        'candidate': None,
                    }))

            _pc.addTrack(CameraVideoTrack())

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
                    answer = data['answer']
                    await _pc.setRemoteDescription(
                        RTCSessionDescription(
                            sdp=answer['sdp'],
                            type=answer['type'],
                        )
                    )
                    print('WebRTC handshake completo ✓')

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
                        print(f'Error añadiendo ICE candidate: {e}')

    except Exception as e:
        print(f'Error en webrtc_client: {e}')


# ============================================================
# ARRANQUE
# ============================================================

dron          = Dron()
dron.navSpeed = 2.5

client_name = 'groundStation' + str(random.randint(1000, 9000))
client      = mqtt.Client(client_name)
client.on_connect = on_connect
client.on_message = on_message

print(f'Connecting to broker {BROKER}:{PORT_MQTT}...')
client.connect(BROKER, PORT_MQTT)
client.loop_start()

# Hilo principal libre — solo mantiene el proceso vivo
# El loop asyncio ya corre en _loop_thread
print('Sistema listo. Esperando comandos MQTT...')
threading.Event().wait()