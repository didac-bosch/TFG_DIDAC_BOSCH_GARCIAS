import paho.mqtt.client as mqtt
import random
import threading
import time
from dronLink.Dron import Dron

BROKER = 'broker.hivemq.com'        #puerto standard hivemq
PORT   = 1883

_monitoring = False

def on_connect(client, userdata, flags, rc):
    if rc == 0:         #Return code = 0 - conexión exitosa
        print('Ground Station connected :)')
        client.subscribe('mobileFlutter/groundStation/#')   #suscripción a mobileFlutter/groundStatio/
        print('waiting for topics...')
    else:
        print(f'Error connecting the broker, code: {rc}')

def monitor_arm_state():
    global _monitoring

    if _monitoring:             #evita  múltiples monitoreos (por ejemplo por varios arms a la vez)
        return

    _monitoring = True
    timeout = time.time() + 60          #límite de 60s

    #Monitoreo arm motores
    time.sleep(1)
    while time.time() < timeout:
        if dron.vehicle is not None:
            armed = dron.vehicle.motors_armed()
            if not armed:
                client.publish('groundStation/mobileFlutter/disarmed', 'disarmed')
                break
        else:
            break
        time.sleep(0.5)
    else:
        client.publish('groundStation/mobileFlutter/disarmed', 'disarmed')

    _monitoring = False

def on_message(client, userdata, message):      #extracción de la acción
    parts   = message.topic.split('/')
    command = parts[2]
    print(f'Command: {command}')

    # CONNECT
    if command == 'connect':
        def conectar():
            print('Connecting to the drone...')
            dron.connect('tcp:127.0.0.1:5763', 115200)    #dirección simulador, cambiar para dron real!
            print('Drone connected!')
            client.publish('groundStation/mobileFlutter/connected', 'connected')
        threading.Thread(target=conectar).start()

    # ARM
    if command == 'arm':
        if dron.state == 'connected':
            dron.arm()
            print('!!!Motors armed!!!')
            client.publish('groundStation/mobileFlutter/armed', 'armed')
            threading.Thread(target=monitor_arm_state, daemon=True).start()
        else:
            print(f'Arm ignorado: estado del dron es "{dron.state}"')

    # DISCONNECT
    if command == 'disconnect':
        def desconectar():
            print('Disconnecting drone...')
            dron.disconnect()
            print('Drone disconnected!')
            client.publish('groundStation/mobileFlutter/disconnected', 'disconnected')
        threading.Thread(target=desconectar).start()


dron = Dron()
clientName = 'groundStation' + str(random.randint(1000, 9000))      #aleatorio para la ID del cliente
client = mqtt.Client(clientName)
client.on_connect = on_connect
client.on_message = on_message

print(f'Connecting the broker. {BROKER}:{PORT}...')
client.connect(BROKER, PORT)
print('Estación de Tierra en espera. Pulsa Ctrl+C para salir.')
client.loop_forever()
