from abc import ABC, abstractmethod

class Sensor(ABC):
    @abstractmethod
    def get_measurements(self) -> dict[str, float]: 
        pass