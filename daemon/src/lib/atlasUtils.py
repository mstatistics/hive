
from __future__ import annotations

from types import TracebackType

from daemon.src.lib.thirdparty.atlasI2c import AtlasI2C


class AtlasSensorError(RuntimeError):
    """Raised when an Atlas sensor rejects a command or cannot be queried."""


class AtlasSensor:
    """High-level, address-specific interface for one Atlas I2C sensor."""

    def __init__(
        self,
        address: int,
        *,
        name: str = "",
        moduletype: str = "",
        bus: int = 1,
    ) -> None:
        if not 0 <= address <= 127:
            raise ValueError("I2C address must be between 0 and 127")

        self.address = address
        self.bus = bus
        self._device = AtlasI2C(address=address, name=name, moduletype=moduletype, bus=bus)

    def _query(self, command: str) -> str:
        response = self._device.query(command)
        if response.startswith("Error"):
            raise AtlasSensorError(response)
        return response

    def _payload(self, response: str) -> str:
        marker = ": "
        if marker not in response:
            raise AtlasSensorError(f"Unexpected sensor response: {response}")
        return response.rsplit(marker, 1)[1].strip()

    def read(self) -> float | list[float]:
        """Read the sensor and return a numeric value, or values, without Atlas response text."""
        payload = self._payload(self._query("R"))
        try:
            values = [float(value.strip()) for value in payload.split(",")]
        except ValueError as exc:
            raise AtlasSensorError(f"Sensor returned a non-numeric reading: {payload}") from exc
        return values[0] if len(values) == 1 else values

    def calibrate(self, calibration: str | float | None = None, value: float | None = None) -> str:
        """
        Send an Atlas calibration command.

        Examples:
        - pH midpoint: sensor.calibrate("mid", 7.0)
        - EC low point: sensor.calibrate("low", 1413)
        - EC clear: sensor.calibrate("clear")
        - Generic midpoint: sensor.calibrate(7.0)
        """
        if value is not None:
            if not isinstance(calibration, str) or not calibration.strip():
                raise ValueError("A calibration point name is required when value is provided")
            command = f"CAL,{calibration.strip()},{value}"
        elif isinstance(calibration, (int, float)):
            command = f"CAL,{calibration}"
        elif calibration is None:
            command = "CAL"
        else:
            calibration = calibration.strip()
            if calibration.lower() == "clear":
                command = "CAL,clear"
            elif "," in calibration or calibration.startswith("CAL"):
                command = calibration if calibration.startswith("CAL") else f"CAL,{calibration}"
            else:
                raise ValueError("Calibration text must be 'clear', a CAL command, or include a value")

        response = self._query(command)
        return self._payload(response)

    def close(self) -> None:
        self._device.close()

    def __enter__(self) -> AtlasSensor:
        return self

    def __exit__(
        self,
        _exc_type: type[BaseException] | None,
        _exc_value: BaseException | None,
        _traceback: TracebackType | None,
    ) -> None:
        self.close()


def list_devices(bus: int = 1) -> list[int]:
    """Return I2C addresses that appear to contain an Atlas device."""
    probe = AtlasI2C(bus=bus)
    try:
        return probe.list_i2c_devices()
    finally:
        probe.close()


def read_sensor(address: int, *, name: str = "", moduletype: str = "", bus: int = 1) -> float | list[float]:
    """Read one sensor by its I2C address."""
    with AtlasSensor(address, name=name, moduletype=moduletype, bus=bus) as sensor:
        return sensor.read()


def calibrate_sensor(
    address: int,
    calibration: str | float | None = None,
    value: float | None = None,
    *,
    name: str = "",
    moduletype: str = "",
    bus: int = 1,
) -> str:
    """Calibrate one sensor by its I2C address."""
    with AtlasSensor(address, name=name, moduletype=moduletype, bus=bus) as sensor:
        return sensor.calibrate(calibration, value)

