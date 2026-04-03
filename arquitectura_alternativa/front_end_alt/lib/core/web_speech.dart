import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:web/web.dart' as web;

//Acceso a API nativa del navegador (SpeechRecognition)


extension type SpeechRecognitionJS._(JSObject _) implements JSObject {    //conversión a tipo extension para poder tratar objetos JavaScript
  external set continuous(bool value);  
  external set interimResults(bool value);
  external set lang(String value);
  external set onresult(JSFunction? value);
  external set onend(JSFunction? value);
  external set onerror(JSFunction? value);
  external set onspeechend(JSFunction? value);
  external void start();
  external void stop();
}


// -   SpeechRecognitionEvent
//     -  SpeechRecognitionResultList  (lista de frases reconocidas)
//         -   SpeechRecognitionResult  (una frase, puede tener varias alternativas)
//              -   SpeechRecognitionAlternative  (una alternativa concreta)
//                   -   transcript: String  (el texto transcrito)
extension type SpeechRecognitionEvent._(JSObject _) implements JSObject {
  external SpeechRecognitionResultList get results;
}

extension type SpeechRecognitionResultList._(JSObject _) implements JSObject {
  external int get length;
  external SpeechRecognitionResult item(int index);
}

extension type SpeechRecognitionResult._(JSObject _) implements JSObject {
  external SpeechRecognitionAlternative item(int index);
}

extension type SpeechRecognitionAlternative._(JSObject _) implements JSObject {
  external String get transcript;
}

extension type SpeechRecognitionErrorEvent._(JSObject _) implements JSObject {
  external String get error;
}

extension type VoidEvent._(JSObject _) implements JSObject {}


// Constructores JS dependiendo del navegador
@JS('SpeechRecognition')
external JSFunction? get _speechRecognition;

@JS('webkitSpeechRecognition')
external JSFunction? get _webkitSpeechRecognition;

SpeechRecognitionJS _createRecognition() {    //en caso de que no se hubiera podido con ninguno de los anteriores
  final ctor = _speechRecognition ?? _webkitSpeechRecognition;
  if (ctor == null) throw Exception('SpeechRecognition not supported');
  return ctor.callAsConstructor() as SpeechRecognitionJS;
}

class WebSpeech {                     //Clase de reconocimiento principal
  SpeechRecognitionJS? _recognition;
  bool _isAvailable = false;

  bool get isAvailable => _isAvailable; //si soporta speech recognition

  // Reacciones a los eventos 
  Function(String text)? onResult;  //cuando se detecta texto 
  Function()? onEnd;  //al terminar de detectar
  Function(String error)? onError;  //si hay error

  Future<bool> initialize() async {     //verificador para comprobar que el navegador soporta la API
    try {
      final hasSpeech = _speechRecognition != null;
      final hasWebkit = _webkitSpeechRecognition != null;

      if (!hasSpeech && !hasWebkit) {
        _isAvailable = false;
        return false;
      }

      _isAvailable = true;
      return true;
    } catch (_) {
      _isAvailable = false;
      return false;
    }
  }

  void startListening({String localeId = 'es-ES'}) {
    if (!_isAvailable) return;

    _recognition = _createRecognition();

    _recognition!.continuous = false;    // push-to-talk
    _recognition!.interimResults = true; // Texto parcias
    _recognition!.lang = localeId;  //Declarado antes como español

    // Resultado parcial o final — actualiza el texto en pantalla
    _recognition!.onresult = ((SpeechRecognitionEvent event) {
      final results = event.results;
      final length = results.length;
      if (length > 0) {
        final transcript = results.item(length - 1).item(0).transcript;
        onResult?.call(transcript);
      }
    }).toJS;

    // Safari bug fix: onspeechend no para automáticamente en Safari.
    _recognition!.onspeechend = ((VoidEvent _) {
      final vendor = web.window.navigator.vendor;
      if (vendor.contains('Apple')) {
        _recognition?.stop();
      }
    }).toJS;

    // notificación onend 
    _recognition!.onend = ((VoidEvent _) {
      onEnd?.call();
    }).toJS;

    _recognition!.onerror = ((SpeechRecognitionErrorEvent event) {  
      onError?.call(event.error);
    }).toJS;

    _recognition!.start();  //enciende micro y empieza a escuchar 
  }

  void stopListening() {
    try {
      _recognition?.stop();
    } catch (_) {}
    _recognition = null;
  }
}