// Distance and DHT temperature/humidity -> Mac; Mac posture -> red LED.
#include <DHT.h>

const int dhtPin = 2;
// Change to DHT22 for a DHT22 / AM2302 sensor.
#ifndef POSTURE_DHT_TYPE
#define POSTURE_DHT_TYPE DHT11
#endif
DHT climate(dhtPin, POSTURE_DHT_TYPE);
const unsigned long CLIMATE_SAMPLE_MS = 2000UL;
unsigned long lastClimateSample = 0;
const int trigPin = 8;
const int echoPin = 9;
const int redPin = 7;

const float TOO_CLOSE_CM = 50.0;
const float WARNING_CM = 60.0;
const float MAX_GOOD_CM = 100.0;
const unsigned long SAMPLE_MS = 200UL;
const unsigned long POSTURE_TIMEOUT_MS = 2000UL;
const unsigned long ECHO_TIMEOUT_US = 30000UL;

char posture = 'U';
unsigned long lastPosture = 0;
unsigned long lastSample = 0;
float distance = -1.0;
char distanceZone = 'N';

void receivePosture() {
  while (Serial.available() > 0) {
    char incoming = Serial.read();
    if (incoming == 'G' || incoming == 'B' || incoming == 'U') {
      posture = incoming;
      lastPosture = millis();
    }
  }
  if (millis() - lastPosture > POSTURE_TIMEOUT_MS) {
    posture = 'U';
  }
}

char classifyDistance(float cm) {
  if (cm <= 0 || cm > MAX_GOOD_CM) return 'N';
  if (cm < TOO_CLOSE_CM) return 'C';
  if (cm < WARNING_CM) return 'W';
  return 'G';
}

void measureDistance() {
  digitalWrite(trigPin, LOW);
  delayMicroseconds(2);
  digitalWrite(trigPin, HIGH);
  delayMicroseconds(10);
  digitalWrite(trigPin, LOW);

  // An absent echo must not block posture heartbeats for a full second.
  unsigned long duration = pulseIn(echoPin, HIGH, ECHO_TIMEOUT_US);
  distance = duration == 0 ? -1.0 : duration * 0.0343 / 2.0;
  distanceZone = classifyDistance(distance);

  // Machine-readable telemetry to the Mac. Do not add unframed debug output.
  Serial.print("D,");
  Serial.print(distance, 1);
  Serial.print(',');
  Serial.println(distanceZone);
}

void measureClimate() {
  float humidity = climate.readHumidity();
  float temperature = climate.readTemperature();  // Celsius
  // Explicit failure frame clears the app's previous reading immediately.
  if (isnan(temperature) || isnan(humidity) || temperature < -40 ||
      temperature > 80 || humidity < 0 || humidity > 100) {
    Serial.println("E,ERR");
    return;
  }
  Serial.print("E,");
  Serial.print(temperature, 1);
  Serial.print(',');
  Serial.println(humidity, 1);
}

void updateIndicators() {
  bool alert = distanceZone == 'C' || posture == 'B';
  digitalWrite(redPin, alert ? HIGH : LOW);
  digitalWrite(LED_BUILTIN, alert ? HIGH : LOW);
}

void setup() {
  pinMode(trigPin, OUTPUT);
  pinMode(echoPin, INPUT);
  pinMode(redPin, OUTPUT);
  pinMode(LED_BUILTIN, OUTPUT);
  digitalWrite(trigPin, LOW);
  digitalWrite(redPin, LOW);
  digitalWrite(LED_BUILTIN, LOW);
  Serial.begin(115200);

  climate.begin();
  // Allow the sensor to settle after power-up before its first reading.
  lastClimateSample = millis();
  lastSample = millis() - SAMPLE_MS;
}

void loop() {
  receivePosture();
  bool sampled = millis() - lastSample >= SAMPLE_MS;
  if (sampled) {
    lastSample = millis();
    measureDistance();
    receivePosture();
  }
  if (millis() - lastClimateSample >= CLIMATE_SAMPLE_MS) {
    lastClimateSample = millis();
    measureClimate();
    receivePosture();
  }
  updateIndicators();
}
