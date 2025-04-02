import adafruit_dht  # type: ignore[import-not-found]
import os
import board  # type: ignore[import-not-found]
from prometheus_client import (
    Gauge,
    Counter,
    generate_latest,
    CONTENT_TYPE_LATEST,
    disable_created_metrics,
)
from tenacity import retry, stop_after_attempt, wait_fixed
from fastapi import FastAPI, Response
import traceback

app = FastAPI()

PIN = os.getenv("PIN", 4)
SENSOR = os.getenv("SENSOR", "2302")
LOCATION = os.getenv("LOCATION")
FAHRENHEIT = os.getenv("FAHRENHEIT", "False").lower() in ("true", "1", "t")

TEMPERATURE_SCALE = "fahrenheit" if FAHRENHEIT else "celsius"

disable_created_metrics()  # type: ignore[no-untyped-call]

HUMIDITY = Gauge(
    "dht_exporter_humidity",
    "Humidity percentage.",
    ["location"],
)

TEMPERATURE = Gauge(
    "dht_exporter_temperature",
    f"Temperature in {TEMPERATURE_SCALE}",
    ["location"],
)

ERRORS = Counter("dht_exporter_error", "dht_exporter errors", ["location"])
ERRORS.labels(LOCATION)


class NoSensorData(Exception):
    pass


@retry(stop=stop_after_attempt(15), wait=wait_fixed(0.2))
async def read_sensor() -> tuple[float, float]:
    sensor_args = {
        "11": adafruit_dht.DHT11,
        "22": adafruit_dht.DHT22,
        "2302": adafruit_dht.DHT22,
    }
    board_pin = getattr(board, f"D{PIN}")
    dht_device = sensor_args[str(SENSOR)](board_pin, use_pulseio=False)

    temperature = dht_device.temperature
    humidity = dht_device.humidity

    if all(v is not None for v in [humidity, temperature]):
        return temperature, humidity
    else:
        raise NoSensorData(
            f"Missing Sensor Data: temperature: {temperature}, humidity: {humidity}"
        )


async def get_temperature_readings() -> dict[str, float]:
    try:
        temperature, humidity = await read_sensor()
    except NoSensorData as e:
        print(e)
        return {}

    if TEMPERATURE_SCALE == "fahrenheit":
        temperature = temperature * (9 / 5) + 32

    response = {"temperature": temperature, "humidity": humidity}
    return response


@app.get("/metrics")
async def metrics() -> Response:
    try:
        metrics = await get_temperature_readings()
        if metrics:
            HUMIDITY.labels(LOCATION).set(metrics["humidity"])
            TEMPERATURE.labels(LOCATION).set(metrics["temperature"])
        else:
            ERRORS.labels(LOCATION).inc()
            HUMIDITY.clear()
            TEMPERATURE.clear()

    except Exception:
        print(traceback.format_exc())
        ERRORS.labels(LOCATION).inc()
        HUMIDITY.clear()
        TEMPERATURE.clear()
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
