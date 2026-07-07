import paho.mqtt.client as mqtt
import random
import threading
import time
import json
from dronLink.Dron import Dron

# Configuración del broker MQTT y su puerto
BROKER = 'broker.hivemq.com'
PORT   = 1883


# variables globales
_monitoring = False

# Función de callback para la conexión al broker MQTT
def on_connect(client, userdata, flags, rc):
    if rc == 0:         #Return code = 0 - conexión exitosa
        print('Ground Station connected :)')
        client.subscribe('mobileFlutter/groundStation/#')   #suscripción a mobileFlutter/groundStation/
        print('waiting for topics...')
    else:
        print(f'Error connecting the broker, code: {rc}')

def process_telemetry_info(telemetry_info):
    payload = json.dumps(telemetry_info)
    client.publish('groundStation/mobileFlutter/telemetry', payload)    #publicación datos telemetría de vuelta 

# función para monitorizar el estado de armado de los motores del dron
def monitor_arm_state():
    global _monitoring

    if _monitoring:
        return

    _monitoring = True

    # Monitoreo arm motores continuo durante todo el vuelo
    time.sleep(1)
    while True:
        if dron.vehicle is not None:
            armed = dron.vehicle.motors_armed()
            if not armed:
                client.publish('groundStation/mobileFlutter/disarmed', 'disarmed')
                break
        else:
            break
        time.sleep(1)  # Comprueba cada 1 segundo para no saturar

    _monitoring = False

# on_message callback para manejar los mensajes recibidos en los tópicos suscritos
def on_message(client, userdata, message):      
    parts   = message.topic.split('/')
    command = parts[2]
    print(f'Command: {command}')

    # CONNECT
    if command == 'connect':
        def conectar():
            print('Connecting to the drone...')
            dron.connect('tcp:127.0.0.1:5763', 115200)    #dirección simulador, cambiar para dron real!
            print('Drone connected!')
           
            dron.frequency = 2 # frecuencia de envío de telemetría (Hz)
            dron.send_telemetry_info(process_telemetry_info)
           
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

    # TAKEOFF
    if command == 'takeoff':
        if dron.state in ('armed', 'flying'):
            altitude = int(message.payload.decode())
            def despegar():
                print(f'Taking off to {altitude}m...')
                dron.takeOff(altitude)
                print('Takeoff complete!')
                client.publish('groundStation/mobileFlutter/flying', 'flying')
            threading.Thread(target=despegar).start()
        else:
            print(f'Not able to take off, dron state: {dron.state}')


    # LAND
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

    # RTL
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

    # SPEED
    if command == 'speed':
        spd = float(message.payload.decode())
        def set_speed():
            print(f'Setting flight speed to {spd} m/s...')
            dron.navSpeed = spd
            dron.changeNavSpeed(spd)
        threading.Thread(target=set_speed).start()

    # MOVE
    if command == 'move':
        direction = message.payload.decode()
        if dron.state in ('flying', 'returning'):
            def mover():
                if direction == 'Stop':           #parar
                    print('Stopping movement...')
                    dron.go('Stop')
                else:
                    print(f'Moving {direction} at {dron.navSpeed} m/s...')  #si no es parar, moverse hacia dirección a vel.
                    dron.go(direction)
            threading.Thread(target=mover).start()
        else:
            print(f'Cannot move. Drone is not flying. State: {dron.state}')


    # DISCONNECT
    if command == 'disconnect':
        def desconectar():
            print('Disconnecting drone...')
            dron.stop_sending_telemetry_info()
            dron.disconnect()
            print('Drone disconnected!')
            client.publish('groundStation/mobileFlutter/disconnected', 'disconnected')
        threading.Thread(target=desconectar).start()


dron = Dron()
dron.navSpeed = 5.0 #velocidad por defecto si no llega otra
clientName = 'groundStation' + str(random.randint(1000, 9000))      #aleatorio para la ID del cliente
client = mqtt.Client(clientName)
client.on_connect = on_connect
client.on_message = on_message

print(f'Connecting the broker. {BROKER}:{PORT}...')
client.connect(BROKER, PORT)
client.loop_forever()