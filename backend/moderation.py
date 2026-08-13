import os

import numpy as np

try:
    import tflite_runtime.interpreter as tflite
except ImportError:
    try:
        import tensorflow as tf  # noqa: F401

        tflite = tf.lite
    except ImportError:
        tflite = None

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODEL_PATH = os.path.join(BASE_DIR, "models", "nsfw_model.tflite")


class ContentModerator:
    """Thin wrapper around a TFLite NSFW model.

    Deliberately fails *closed*: if no model is present, or the model is broken,
    ``predict`` returns a neutral 0.5 so the image lands in quarantine rather
    than being silently approved.
    """

    def __init__(self):
        self.interpreter = None
        self.input_details = None
        self.output_details = None
        if tflite and os.path.isfile(MODEL_PATH) and os.path.getsize(MODEL_PATH) > 0:
            try:
                self.interpreter = tflite.Interpreter(model_path=MODEL_PATH)
                self.interpreter.allocate_tensors()
                self.input_details = self.interpreter.get_input_details()
                self.output_details = self.interpreter.get_output_details()
            except Exception:  # noqa: BLE001
                self.interpreter = None

    @property
    def loaded(self) -> bool:
        return self.interpreter is not None

    def predict(self, image_path):
        if not self.interpreter:
            return 0.5, "Model not loaded"

        from PIL import Image as PILImage

        img = PILImage.open(image_path).convert("RGB")

        input_detail = self.input_details[0]
        input_shape = input_detail["shape"]

        # Assume NHWC [1, H, W, C]; fall back to HxW for [1, H, W] or [H, W].
        if len(input_shape) == 4:
            height, width = input_shape[1], input_shape[2]
        elif len(input_shape) == 3:
            height, width = input_shape[1], input_shape[2]
        else:
            height, width = 224, 224

        img = img.resize((width, height), PILImage.LANCZOS)
        arr = np.asarray(img, dtype=np.float32) / 255.0

        # Some models expect float [0,1], others uint8 [0,255].
        dtype = input_detail["dtype"]
        if dtype == np.uint8:
            arr = (arr * 255.0).astype(np.uint8)
        elif dtype in (np.float16, np.float32, np.float64):
            arr = arr.astype(dtype)

        arr = np.expand_dims(arr, axis=0)

        try:
            self.interpreter.set_tensor(input_detail["index"], arr)
            self.interpreter.invoke()
            output_data = self.interpreter.get_tensor(self.output_details[0]["index"])
        except Exception:  # noqa: BLE001
            return 0.5, "Moderation error"

        # Reduce whatever shape the model returns to a single scalar score.
        flat = np.asarray(output_data).flatten()
        if flat.size == 0:
            return 0.5, "Empty output"
        score = float(flat[0])
        return score, "Success"
