#pragma once
#include <cmath>
using std::isnan;
const int DHT11 = 11, DHT22 = 22;
class DHT {
public:
  int pin, type, reads = 0;
  bool started = false;
  float temperature = 23.4f, humidity = 56.7f;
  DHT(int pin, int type) : pin(pin), type(type) {}
  void begin() { started = true; }
  float readHumidity() { ++reads; return humidity; }
  float readTemperature() { return temperature; }
};
