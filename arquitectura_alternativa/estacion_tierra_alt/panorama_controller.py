import base64
import os
import shutil
import statistics
import tempfile
import threading
import time

import cv2
import numpy as np

# ============================================================
# PanoramaController — modo "panorama360" para el Tello.
#
# Porta la logica de escaneo/cosido de escaneo_entorno_tello.py, adaptada a la
# arquitectura de arquitectura_alternativa:
#   - NO crea su propio Tello(): recibe el TelloDron compartido de la ET.
#   - NO abre su propio lector UDP: usa tello.get_frame() (el mismo stream que
#     ya consume WebRTC), evitando el conflicto de doble-lector sobre el UDP.
#   - Modo de MEDIO VUELO: no despega ni aterriza; gira 360 en la altitud actual.
#   - Al terminar de coser BORRA todas las fotos intermedias y solo entrega la
#     panoramica final (JPEG comprimido -> base64) via el callback on_done.
# Corre en un hilo daemon, igual que FollowController; se para con stop().
# ============================================================

# --- Parametros de escaneo (identicos al script original) ---
PASO_YAW      = 10     # grados de giro por paso
ESTAB_S       = 1.0    # estabilizacion antes de cada foto
UMBRAL_CIERRE = 0.6    # correlacion minima para dar la vuelta por cerrada
UMBRAL_PASO   = 0.5    # correlacion minima para fiarse de un desplazamiento

# --- Compresion de la panoramica para el transporte MQTT ---
OUT_MAX_H     = 480    # altura maxima de salida (px); se reescala para caber en MQTT
JPEG_QUALITY  = 60     # calidad JPEG del panorama que viaja al frontend


# Coge dos fotos consecutivas y devuelve la correlacion y el desplazamiento
# horizontal en px de la segunda respecto a la primera.
def _desplazamiento(a, b):
    ga = cv2.cvtColor(a, cv2.COLOR_BGR2GRAY)
    w = b.shape[1]
    banda = cv2.cvtColor(b, cv2.COLOR_BGR2GRAY)[:, w // 3:2 * w // 3]
    _, score, _, loc = cv2.minMaxLoc(cv2.matchTemplate(ga, banda, cv2.TM_CCOEFF_NORMED))
    return score, abs(loc[0] - w // 3)


# Calcula los desplazamientos entre fotos consecutivas (todas).
def _desplazamientos(frames):
    n = len(frames)
    pares = [_desplazamiento(frames[i], frames[(i + 1) % n]) for i in range(n)]
    brutos = [max(1, d) for _, d in pares]
    med = statistics.median(brutos)
    pasos = [b if (sc >= UMBRAL_PASO and b <= 2 * med) else int(round(med))
             for (sc, _), b in zip(pares, brutos)]
    cierra = pares[-1][0] >= UMBRAL_CIERRE
    return pasos, cierra


# Cose las fotos en un mosaico horizontal, con ventanas de ponderacion para
# suavizar los bordes y evitar costuras visibles. Conserva el orden de canal de
# la entrada (aqui RGB, ya que los frames vienen de tello.get_frame()).
def _mosaico(frames, pasos, cierra):
    # Posicion horizontal donde va cada foto en el lienzo final: la suma de todos
    # los desplazamientos anteriores. W es el ancho total resultante.
    h, n = frames[0].shape[0], len(frames)
    offsets = [sum(pasos[:i]) for i in range(n)]
    W = sum(pasos) if cierra else offsets[-1] + pasos[-2]
    # Se acumula en float y se lleva un lienzo de pesos aparte: al final se divide
    # uno por otro para obtener la media ponderada (media normal = costuras).
    acc = np.zeros((h, W, 3), np.float32)
    peso = np.zeros((h, W, 1), np.float32)
    for i, (f, off) in enumerate(zip(frames, offsets)):
        s = pasos[i] if cierra or i < n - 1 else pasos[i - 1]
        c = f.shape[1] // 2
        # Ventana triangular: cada foto pesa 1 en su centro y 0 en los extremos,
        # asi dos fotos vecinas se funden gradualmente en la zona que comparten.
        win = (1 - np.abs(np.linspace(-1, 1, 2 * s))).reshape(1, 2 * s, 1).astype(np.float32)
        # Solo se usa la franja central de cada foto: los bordes son los que mas
        # deformacion de lente tienen.
        franja = f[:, c - s:c + s].astype(np.float32)
        col = np.arange(2 * s) + off - s
        if cierra:
            # La vuelta cerro: el lienzo es circular y lo que se sale por un lado
            # entra por el otro (de ahi el modulo).
            col %= W
        else:
            valido = (col >= 0) & (col < W)
            col, franja, win = col[valido], franja[:, valido], win[:, valido]
        acc[:, col] += franja * win
        peso[:, col] += win
    # El maximo con 1e-6 evita dividir por cero en columnas sin ninguna foto.
    return (acc / np.maximum(peso, 1e-6)).astype(np.uint8)


class PanoramaController:

    # Arranca el escaneo nada mas crearse: se queda con el Tello compartido, prepara
    # una carpeta temporal para las fotos y lanza el hilo daemon que gira y cose.
    def __init__(self, tello_ref, on_status=None, on_done=None):
        self._tello = tello_ref
        self._on_status = on_status   # callback(str): 'scanning'|'stitching'|'done'|'error'|'off'
        self._on_done = on_done       # callback(str): panoramica final en base64 (JPEG)
        self._active = True
        self._tmpdir = tempfile.mkdtemp(prefix='panorama_')
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    # ------------------------------------------------------------------
    # Avisa al frontend del estado del panorama sin reventar si el callback falla
    def _status(self, s):
        if self._on_status is not None:
            try:
                self._on_status(s)
            except Exception:
                pass

    def _yaw(self):
        # Yaw real de la IMU via djitellopy crudo. Se lee del stream de estado
        # (no del socket de comandos), asi que no necesita el _sdk_lock.
        try:
            return float(self._tello._tello.get_yaw())
        except Exception:
            return None

    def _grab_frame(self, timeout_s=2.0):
        # Devuelve una copia del frame mas reciente del stream compartido, o None.
        fin = time.time() + timeout_s
        while time.time() < fin and self._active:
            img = self._tello.get_frame()
            if img is not None:
                return img.copy()
            time.sleep(0.05)
        return None

    def _save_tmp(self, name, frame_rgb):
        # Los frames vienen en RGB; se convierten a BGR para que cv2.imwrite los
        # guarde con los colores correctos (fotos temporales de depuracion).
        cv2.imwrite(os.path.join(self._tmpdir, name),
                    cv2.cvtColor(frame_rgb, cv2.COLOR_RGB2BGR))

    # Mide los desplazamientos entre fotos y las cose en la panoramica final
    def _construir(self, frames):
        if len(frames) < 3:
            print('[PANORAMA] sin fotos suficientes')
            return None
        pasos, cierra = _desplazamientos(frames)
        pano = _mosaico(frames, pasos, cierra)
        print(f'[PANORAMA] mosaico listo ({pano.shape[1]}x{pano.shape[0]})')
        return pano

    def _encode(self, pano_rgb):
        # Reescala en altura para acotar el tamano del mensaje MQTT y codifica a
        # JPEG. cv2.imencode espera BGR para producir un JPEG con colores normales.
        h, w = pano_rgb.shape[:2]
        if h > OUT_MAX_H:
            scale = OUT_MAX_H / float(h)
            pano_rgb = cv2.resize(pano_rgb, (max(1, int(w * scale)), OUT_MAX_H),
                                  interpolation=cv2.INTER_AREA)
        bgr = cv2.cvtColor(pano_rgb, cv2.COLOR_RGB2BGR)
        ok, buf = cv2.imencode('.jpg', bgr, [cv2.IMWRITE_JPEG_QUALITY, JPEG_QUALITY])
        if not ok:
            raise RuntimeError('no se pudo codificar el panorama')
        return base64.b64encode(buf.tobytes()).decode('ascii')

    # ------------------------------------------------------------------
    # Cuerpo del hilo: foto inicial -> gira 360 en pasos captando fotos -> cose ->
    # entrega el resultado por on_done. Al final borra siempre las fotos temporales.
    def _run(self):
        frames = []
        try:
            self._status('scanning')

            # Foto inicial (referencia del punto de partida) antes de girar.
            img = self._grab_frame()
            if img is not None:
                frames.append(img)
                self._save_tmp('foto_00.jpg', img)

            # Gira en pasos pequenos hasta completar ~360 reales (medidos con la
            # IMU, porque rotate no gira exactamente lo que se le pide). SIN
            # despegue ni ascenso: se mantiene la altitud actual.
            MAX_PASOS = 3 * (360 // PASO_YAW)
            yaw_prev = self._yaw()
            giro = 0.0
            paso = 0
            while self._active and giro < 360 - PASO_YAW / 2 and paso < MAX_PASOS:
                paso += 1
                self._tello.rotate(PASO_YAW)   # cw; bloquea + cooldown interno
                time.sleep(ESTAB_S)
                yaw = self._yaw()
                if yaw is not None and yaw_prev is not None:
                    giro += abs(((yaw - yaw_prev + 180) % 360) - 180)
                    yaw_prev = yaw
                else:
                    giro += PASO_YAW
                img = self._grab_frame()
                if img is not None:
                    frames.append(img)
                    self._save_tmp(f'foto_{paso:02d}.jpg', img)

            if not self._active:
                print('[PANORAMA] cancelado por stop()')
                self._status('off')
                return

            print(f'[PANORAMA] {paso} fotos, giro real {giro:.0f} grados; cosiendo...')
            self._status('stitching')
            pano = self._construir(frames)
            if pano is None:
                self._status('error')
                return

            b64 = self._encode(pano)
            self._status('done')
            if self._on_done is not None:
                try:
                    self._on_done(b64)
                except Exception as e:
                    print(f'[PANORAMA] error en on_done: {e}')
        except Exception as e:
            print(f'[PANORAMA] error: {e}')
            self._status('error')
        finally:
            # Borra TODAS las fotos intermedias: solo sobrevive la panoramica
            # (ya entregada por on_done al frontend).
            shutil.rmtree(self._tmpdir, ignore_errors=True)
            self._active = False

    # ------------------------------------------------------------------
    # Cancela el escaneo, espera a que el hilo muera y deja el dron quieto
    def stop(self):
        self._active = False
        th = getattr(self, '_thread', None)
        if th is not None and th.is_alive() and th is not threading.current_thread():
            th.join(timeout=2.0)
        # Deja el dron quieto (por si se aborta a media rotacion).
        try:
            self._tello.rc(0, 0, 0, 0)
        except Exception:
            pass
