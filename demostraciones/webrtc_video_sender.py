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
# SENDER — CAPTURA DE CÁMARA + DETECCIÓN YOLO + STREAM WEBRTC
#
# FUNCIONAMIENTO:
#   1. Carga YOLOv5s y abre la cámara al arrancar
#   2. Espera conexión de Flutter por WebSocket (señalización)
#   3. Handshake WebRTC: envía offer, espera answer de Flutter
#   4. Arranca el stream: cada frame capturado se procesa y envía
#      · Cada 25 frames → YOLO detecta todos los objetos
#      · Dibuja bbox + nombre + confianza sobre el frame
#      · El frame procesado fluye a Flutter por WebRTC
#
# DETECCIÓN:
#   - Modelo: YOLOv5s 
#   - Frecuencia: cada 25 frames 
#   - Muestra todos los objetos detectados con su % de confianza
# ============================================================


# carga del modelo YOLOv5
model = torch.hub.load('ultralytics/yolov5', 'yolov5s', pretrained=True)
model.eval()


class CustomVideoStreamTrack(VideoStreamTrack):
    def __init__(self, camera_id):
        super().__init__()
        print("Preparando la cámara ....")
        self.cap = cv2.VideoCapture(camera_id)
        print("Cámara preparada")
        self.frame_count = 0
        self.detecciones = []   # lista de (x1, y1, x2, y2, label, conf) de todos los objetos detectados


    async def recv(self):
        self.frame_count += 1
        print(f"Sending frame {self.frame_count}")
        ret, frame = self.cap.read()
        if not ret:
            print("Failed to read frame from camera")
            return None


        # detección cada 25 frames para no saturar la CPU
        if self.frame_count % 25 == 0:
            img_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            results = model(img_rgb)
            self.detecciones = []
            for *box, conf, cls in results.xyxy[0]:         # itera todos los objetos detectados
                x1, y1, x2, y2 = map(int, box)
                label = model.names[int(cls.item())]
                confidence = float(conf.item())             # confianza entre 0.0 y 1.0
                self.detecciones.append((x1, y1, x2, y2, label, confidence))


        # dibuja bbox + nombre + porcentaje de confianza para cada detección activa
        for (x1, y1, x2, y2, label, confidence) in self.detecciones:
            text = f"{label} ({confidence * 100:.0f}%)"     # ej: "person (94%)"
            cv2.rectangle(frame, (x1, y1), (x2, y2), (0, 255, 0), 2)
            cv2.putText(frame, text, (x1, y1 - 10),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 0), 2)


        frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)


        # Add timestamp to the frame
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
        cv2.putText(frame, timestamp, (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 1, (0, 255, 0), 2, cv2.LINE_AA)


        video_frame = VideoFrame.from_ndarray(frame, format="rgb24")
        video_frame.pts = self.frame_count
        video_frame.time_base = fractions.Fraction(1, 30)
        return video_frame


async def handle_client(websocket):     # protocolo de handshake mediante WebSocket 
    global video_sender
    print("Se ha conectado el receptor")
    pc = RTCPeerConnection()
    video_sender = CustomVideoStreamTrack(0)
    pc.addTrack(video_sender)           # añade el track de vídeo a la conexión WebRTC

    # crear y enviar la offer a Flutter
    offer = await pc.createOffer()
    await pc.setLocalDescription(offer)
    print("oferta")
    await websocket.send(json.dumps(
                    {"type": "sdp", "sdp": pc.localDescription.sdp,
                     "sdp_type": pc.localDescription.type}))

    try:
        print("Espero respuesta")
        async for message in websocket:
            data = json.loads(message)
            if data.get("type") == "sdp":
                print("Recibo aceptación")
                desc = RTCSessionDescription(sdp=data["sdp"], type=data["sdp_type"])
                await pc.setRemoteDescription(desc)  # handshake completado, arranca el stream
                print("Pongo en marcha el stream")

    except websockets.ConnectionClosed:
        print("❌ Conexión cerrada.")
    finally:
        cv2.destroyAllWindows()


async def main():
    global video_sender
    HOST = '0.0.0.0'   # escucha en todas las interfaces de red
    PORT = 9999
    video_sender = CustomVideoStreamTrack(0)
    print(f"🖥️ Esperando conexión en ws://{HOST}:{PORT}")
    async with websockets.serve(handle_client, HOST, PORT):
        await asyncio.Future()  # mantiene el servidor activo indefinidamente


if __name__ == "__main__":
    asyncio.run(main())
