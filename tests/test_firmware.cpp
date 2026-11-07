// Host simulation of the actual sketch; no Arduino or sensor needed.
#include <cassert>
#include <deque>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>

const int LOW = 0, HIGH = 1, INPUT = 0, OUTPUT = 1, LED_BUILTIN = 13;
unsigned long clockMs = 0, echoDuration = 0, echoTimeout = 0;
int pins[14] = {};
void pinMode(int, int) {}
void digitalWrite(int pin, int value) { pins[pin] = value; }
void delayMicroseconds(int) {}
unsigned long millis() { return clockMs; }
unsigned long pulseIn(int, int, unsigned long timeout) {
  echoTimeout = timeout;
  return echoDuration;
}
struct SerialStub {
  std::deque<char> incoming;
  std::string outgoing;
  long baud = 0;
  void begin(long rate) { baud = rate; }
  int available() { return incoming.size(); }
  char read() { char c = incoming.front(); incoming.pop_front(); return c; }
  void print(const char *s) { outgoing += s; }
  void print(char c) { outgoing += c; }
  void print(float value, int precision) {
    std::ostringstream stream;
    stream << std::fixed << std::setprecision(precision) << value;
    outgoing += stream.str();
  }
  void println(const char *s) { print(s); outgoing += "\r\n"; }
  void println(float f, int precision) { print(f, precision); outgoing += "\r\n"; }
  void println(char c) { print(c); outgoing += "\r\n"; }
} Serial;

#include "../arduino/PostureReceiver/PostureReceiver.ino"

int main() {
  setup();
  assert(Serial.baud == 115200);
  assert(climate.started && climate.pin == 2 && climate.type == DHT11);
  assert(pins[redPin] == LOW);
  assert(classifyDistance(-1) == 'N');
  assert(classifyDistance(0) == 'N');
  assert(classifyDistance(49.9) == 'C');
  assert(classifyDistance(50) == 'W');
  assert(classifyDistance(59.9) == 'W');
  assert(classifyDistance(60) == 'G');
  assert(classifyDistance(100) == 'G');
  assert(classifyDistance(100.1) == 'N');

  echoDuration = 2500;  // 42.9 cm: alert immediately, even without the Mac.
  loop();
  assert(echoTimeout == 30000);
  assert(pins[redPin] == HIGH);
  assert(Serial.outgoing == "D,42.9,C\r\n");
  Serial.outgoing.clear();
  loop();
  assert(Serial.outgoing.empty());  // No flooding between 200 ms samples.

  clockMs = 200;
  echoDuration = 4500;  // 77.2 cm: good distance clears distance alert.
  Serial.incoming.push_back('G');
  loop();
  assert(pins[redPin] == LOW);
  assert(Serial.outgoing == "D,77.2,G\r\n");
  Serial.incoming.push_back('B');
  loop();
  assert(pins[redPin] == HIGH);  // Camera can also light the red LED.
  clockMs = 2201;
  loop();
  assert(posture == 'U');
  assert(pins[redPin] == LOW);  // Expired camera heartbeat clears its alert.

  clockMs = 2401;
  echoDuration = 2500;
  loop();
  assert(pins[redPin] == HIGH);  // Distance works with the Mac disconnected.
  clockMs = 2601;
  echoDuration = 0;
  Serial.outgoing.clear();
  loop();
  assert(distance == -1);
  assert(pins[redPin] == LOW);
  assert(Serial.outgoing == "D,-1.0,N\r\n");
  clockMs = 4201;
  Serial.outgoing.clear();
  loop();
  assert(Serial.outgoing == "D,-1.0,N\r\nE,23.4,56.7\r\n");
  int climateReads = climate.reads;
  clockMs = 4401;
  loop();
  assert(climate.reads == climateReads);  // Climate does not run at distance rate.
  clockMs = 6201;
  climate.temperature = NAN;
  Serial.outgoing.clear();
  loop();
  assert(Serial.outgoing == "D,-1.0,N\r\nE,ERR\r\n");
  clockMs = 8201;
  climate.temperature = 0;
  climate.humidity = 0;
  Serial.outgoing.clear();
  loop();
  assert(Serial.outgoing == "D,-1.0,N\r\nE,0.0,0.0\r\n");
  // Unsigned timer arithmetic remains valid across millis() rollover.
  lastClimateSample = ~0UL - 1000;
  clockMs = 1000;
  climate.humidity = 101;
  Serial.outgoing.clear();
  loop();
  assert(Serial.outgoing.find("E,ERR") != std::string::npos);
  std::cout << "PASS: climate pin, sampling, values, failure, rollover;  firmware thresholds, telemetry, red LED, heartbeat timeout, and no echo\n";
}
