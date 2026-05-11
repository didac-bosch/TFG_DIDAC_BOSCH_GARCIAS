import asyncio
import json
import cv2
import websockets
from aiortc import RTCPeerConnection, RTCSessionDescription, VideoStreamTrack
from av import VideoFrame
import fractions
from datetime import datetime
import torch

# ============================================================
# SENDER — CÁMARA + YOLO + WEBRTC con controles desde Flutter
#
# NUEVAS FEATURES respecto a la versión básica:
#
# 1. Modo de detección (detection_mode):
#    - 'all'    → detecta y dibuja todos los objetos (comportamiento original)
#    - 'person' → solo detecta y dibuja personas (class 'person' en COCO)
#    - 'none'   → YOLO no corre, no se dibujan bboxes
#    Flutter envía: {"type": "detection_mode", "mode": "all|person|none"}
#
# 2. Captura de frame (save_next_frame):
#    Flutter envía: {"type": "capture"}
#    → Python guarda el frame actual (con anotaciones) como PNG
#    → Responde con: {"type":"ack","action":"capture_saved","filename":"..."}
#
# 3. Grabación de vídeo:
#    Flutter envía: {"type": "record_start"} / {"type": "record_stop"}
#    → Python abre/cierra un VideoWriter de OpenCV (mp4)
#    → Responde con acks de record_started / record_stopped
#
# CANAL DE CONTROL:
#    El mismo WebSocket del handshake permanece abierto durante toda
#    la sesión. Los mensajes SDP del handshake y los comandos de control
#    se distinguen por el campo "type".
# ============================================================

model = torch.hub.load('ultralytics/yolov5', 'yolov5s', pretrained=True)
model.eval()


class CustomVideoStreamTrack(VideoStreamTrack):
    def __init__(self, camera_id):
        super().__init__()
        print("Preparando la cámara ....")
        self.cap = cv2.VideoCapture(camera_id)
        print("Cámara preparada")
        self.frame_count = 0
        self.detecciones = []

        # Control de detección: 'all', 'person', 'none'
        self.detection_mode = 'all'

        # Flag: guardar el próximo frame como PNG
        self.save_next_frame = False

        # Control de grabación de vídeo
        self.is_recording = False
        self.video_writer = None
        self.recording_filename = None

        # Callback para enviar acks a Flutter — se asigna en handle_client
        self.send_ack = None

    async def recv(self):
        self.frame_count += 1
        ret, frame = self.cap.read()
        if not ret:
            print("Failed to read frame from camera")
            return None

        # ── DETECCIÓN YOLO (solo si el modo no es 'none') ─────────────
        # Se ejecuta cada 25 frames para no saturar la CPU
        if self.frame_count % 25 == 0 and self.detection_mode != 'none':
            img_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            results = model(img_rgb)
            self.detecciones = []
            for *box, conf, cls in results.xyxy[0]:
                x1, y1, x2, y2 = map(int, box)
                label = model.names[int(cls.item())]
                confidence = float(conf.item())
                # En modo 'person' solo se guardan detecciones de personas
                if self.detection_mode == 'person' and label != 'person':
                    continue
                self.detecciones.append((x1, y1, x2, y2, label, confidence))

        # Limpiar detecciones si se cambia a modo 'none'
        if self.detection_mode == 'none':
            self.detecciones = []

        # ── DIBUJAR BBOXES ─────────────────────────────────────────────
        # Verde para 'all', naranja para 'person'
        color = (0, 255, 0) if self.detection_mode == 'all' else (0, 150, 255)
        for (x1, y1, x2, y2, label, confidence) in self.detecciones:
            text = f"{label} ({confidence * 100:.0f}%)"
            cv2.rectangle(frame, (x1, y1), (x2, y2), color, 2)
            cv2.putText(frame, text, (x1, y1 - 10),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.6, color, 2)

        # ── TIMESTAMP ─────────────────────────────────────────────────
        ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
        cv2.putText(frame, ts, (10, 30), cv2.FONT_HERSHEY_SIMPLEX,
                    0.8, (0, 255, 0), 2, cv2.LINE_AA)

        # ── GRABACIÓN ─────────────────────────────────────────────────
        if self.is_recording and self.video_writer is not None:
            self.video_writer.write(frame)  # OpenCV escribe en BGR

        # ── CAPTURA ───────────────────────────────────────────────────
        if self.save_next_frame:
            self.save_next_frame = False
            filename = f"capture_{datetime.now().strftime('%Y%m%d_%H%M%S')}.png"
            cv2.imwrite(filename, frame)
            print(f"📸 Captura guardada: {filename}")
            if self.send_ack:
                asyncio.ensure_future(self.send_ack({
                    'type': 'ack',
                    'action': 'capture_saved',
                    'filename': filename
                }))

        # ── ENVIAR FRAME POR WEBRTC ────────────────────────────────────
        frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        video_frame = VideoFrame.from_ndarray(frame_rgb, format="rgb24")
        video_frame.pts = self.frame_count
        video_frame.time_base = fractions.Fraction(1, 30)
        return video_frame

    def start_recording(self):
        """Abre un VideoWriter de OpenCV para grabar en MP4."""
        h = int(self.cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        w = int(self.cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        self.recording_filename = f"video_{datetime.now().strftime('%Y%m%d_%H%M%S')}.mp4"
        fourcc = cv2.VideoWriter_fourcc(*'mp4v')
        self.video_writer = cv2.VideoWriter(
            self.recording_filename, fourcc, 30.0, (w, h))
        self.is_recording = True
        print(f"🎥 Grabación iniciada: {self.recording_filename}")

    def stop_recording(self):
        """Cierra el VideoWriter y devuelve el nombre del archivo."""
        self.is_recording = False
        if self.video_writer:
            self.video_writer.release()
            self.video_writer = None
        filename = self.recording_filename
        self.recording_filename = None
        print(f"🎥 Grabación detenida: {filename}")
        return filename


async def handle_client(websocket):
    global video_sender
    print("Se ha conectado el receptor")
    pc = RTCPeerConnection()
    video_sender = CustomVideoStreamTrack(0)
    pc.addTrack(video_sender)

    # Función para responder a Flutter por WebSocket
    async def send_ack(data):
        try:
            await websocket.send(json.dumps(data))
        except Exception as e:
            print(f"Error enviando ack: {e}")

    video_sender.send_ack = send_ack

    # Crear y enviar offer a Flutter
    offer = await pc.createOffer()
    await pc.setLocalDescription(offer)
    await websocket.send(json.dumps({
        "type": "sdp",
        "sdp": pc.localDescription.sdp,
        "sdp_type": pc.localDescription.type
    }))

    try:
        # Este loop permanece activo toda la sesión para recibir
        # tanto el SDP del handshake como los comandos de control
        async for message in websocket:
            data = json.loads(message)

            # ── HANDSHAKE WEBRTC ──────────────────────────────────────
            if data.get("type") == "sdp":
                desc = RTCSessionDescription(
                    sdp=data["sdp"], type=data["sdp_type"])
                await pc.setRemoteDescription(desc)
                print("✅ Stream WebRTC activo")

            # ── CAMBIO DE MODO DE DETECCIÓN ───────────────────────────
            elif data.get("type") == "detection_mode":
                mode = data.get("mode", "all")
                video_sender.detection_mode = mode
                video_sender.detecciones = []  # limpiar bboxes anteriores
                print(f"🎯 Modo de detección: {mode}")

            # ── CAPTURA ───────────────────────────────────────────────
            elif data.get("type") == "capture":
                video_sender.save_next_frame = True
                print("📸 Captura solicitada")

            # ── INICIAR GRABACIÓN ─────────────────────────────────────
            elif data.get("type") == "record_start":
                if not video_sender.is_recording:
                    video_sender.start_recording()
                    await send_ack({
                        'type': 'ack',
                        'action': 'record_started',
                        'filename': video_sender.recording_filename
                    })

            # ── DETENER GRABACIÓN ─────────────────────────────────────
            elif data.get("type") == "record_stop":
                if video_sender.is_recording:
                    filename = video_sender.stop_recording()
                    await send_ack({
                        'type': 'ack',
                        'action': 'record_stopped',
                        'filename': filename
                    })

    except websockets.ConnectionClosed:
        print("❌ Conexión cerrada.")
    finally:
        # Asegurarse de cerrar la grabación si la conexión se interrumpe
        if video_sender.is_recording:
            video_sender.stop_recording()
        cv2.destroyAllWindows()


async def main():
    global video_sender
    HOST = '0.0.0.0'
    PORT = 9999
    video_sender = CustomVideoStreamTrack(0)
    print(f"🖥️ Esperando conexión en ws://{HOST}:{PORT}")
    async with websockets.serve(handle_client, HOST, PORT):
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())