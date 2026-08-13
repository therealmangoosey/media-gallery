import numpy as np
import os
try:
    # try to use tflite_runtime if available (lighter)
    import tflite_runtime.interpreter as tflite
except ImportError:
    try:
        import tensorflow.lite as tflite
    except ImportError:
        tflite = None

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODEL_PATH = os.path.join(BASE_DIR, "models", "nsfw_model.tflite")

class ContentModerator:
    def __init__(self):
        self.interpreter = None
        self.input_details = None
        self.output_details = None
        # Only load a real model: skip empty placeholder files and never let a
        # broken model file crash the whole app (we fail closed instead).
        if tflite and os.path.isfile(MODEL_PATH) and os.path.getsize(MODEL_PATH) > 0:
            try:
                self.interpreter = tflite.Interpreter(model_path=MODEL_PATH)
                self.interpreter.allocate_tensors()
                self.input_details = self.interpreter.get_input_details()
                self.output_details = self.interpreter.get_output_details()
            except Exception:
                self.interpreter = None

    def predict(self, image_path):
        if not self.interpreter:
            return 0.5, "Model not loaded" # Default to neutral/quarantine

        from PIL import Image as PILImage
        img = PILImage.open(image_path).convert('RGB')

        # Resize according to model requirements (usually 224x224)
        input_shape = self.input_details[0]['shape']
        img = img.resize((input_shape[1], input_shape[2]))

        input_data = np.expand_dims(np.asarray(img), axis=0).astype(np.float32)
        # Normalize if necessary (depends on the model used)
        input_data = input_data / 255.0

        self.interpreter.set_tensor(self.input_details[0]['index'], input_data)
        self.interpreter.invoke()

        output_data = self.interpreter.get_tensor(self.output_details[0]['index'])
        # Return probability of NSFW
        score = float(output_data[0][0])
        return score, "Success"
