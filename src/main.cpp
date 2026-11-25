#include <Arduino.h>
#include <algorithm>
#include <bitset>
#include <cerrno>
#include <cstring>
#include <dirent.h>
#include <LittleFS.h>
#include <SD.h>
#include <SPI.h>
#include <esp_camera.h>
#include <esp_littlefs.h>
#include <esp_partition.h>
#include <unistd.h>

namespace {
constexpr uint8_t shutterPin = D1;  // XIAO D1 is GPIO2.
constexpr uint8_t sdChipSelect = 21;  // Sense expansion board microSD slot.
constexpr uint32_t debounceMs = 30;
constexpr unsigned maxPhotoNumber = 9999;
constexpr char flashMount[] = "/littlefs";
constexpr char flashPartition[] = "spiffs";
constexpr char captureDirectory[] = "/DCIM";
constexpr char temporaryImage[] = "/DCIM/CAPTURE.TMP";

fs::FS *photoStorage = nullptr;
int rawButton = HIGH;
int stableButton = HIGH;
uint32_t rawChangedAt = 0;
unsigned nextPhoto = 1;

bool setupCamera() {
    camera_config_t config{};
    config.ledc_channel = LEDC_CHANNEL_0;
    config.ledc_timer = LEDC_TIMER_0;
    config.pin_d0 = 15;
    config.pin_d1 = 17;
    config.pin_d2 = 18;
    config.pin_d3 = 16;
    config.pin_d4 = 14;
    config.pin_d5 = 12;
    config.pin_d6 = 11;
    config.pin_d7 = 48;
    config.pin_xclk = 10;
    config.pin_pclk = 13;
    config.pin_vsync = 38;
    config.pin_href = 47;
    config.pin_sccb_sda = 40;
    config.pin_sccb_scl = 39;
    config.pin_pwdn = -1;
    config.pin_reset = -1;
    config.xclk_freq_hz = 20000000;
    config.pixel_format = PIXFORMAT_JPEG;
    config.jpeg_quality = 12;
    config.fb_count = 1;
    config.grab_mode = CAMERA_GRAB_WHEN_EMPTY;
    const bool hasPsram = psramFound();
    config.frame_size = hasPsram ? FRAMESIZE_SVGA : FRAMESIZE_QVGA;
    config.fb_location = hasPsram ? CAMERA_FB_IN_PSRAM : CAMERA_FB_IN_DRAM;

    const esp_err_t error = esp_camera_init(&config);
    if (error != ESP_OK) {
        Serial.printf("Camera init failed: 0x%X\n", static_cast<unsigned>(error));
        return false;
    }
    Serial.printf("Camera ready: %s\n", hasPsram ? "800x600 JPEG" : "320x240 JPEG");
    return true;
}

bool flashPartitionIsBlank() {
    const esp_partition_t *partition =
        esp_partition_find_first(ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_DATA_SPIFFS, flashPartition);
    if (!partition) {
        return false;
    }
    uint8_t buffer[512];
    for (size_t offset = 0; offset < partition->size; offset += sizeof(buffer)) {
        const size_t count = std::min<size_t>(sizeof(buffer), partition->size - offset);
        if (esp_partition_read(partition, offset, buffer, count) != ESP_OK ||
            !std::all_of(buffer, buffer + count, [](uint8_t byte) { return byte == 0xFF; })) {
            return false;
        }
    }
    return true;
}

bool preparePhotoDirectory(fs::FS &storage) {
    if (!storage.exists(captureDirectory)) {
        return storage.mkdir(captureDirectory);
    }
    File directory = storage.open(captureDirectory);
    return directory && directory.isDirectory();
}

fs::FS *setupPhotoStorage() {
    SPI.begin(SCK, MISO, MOSI, sdChipSelect);
    if (SD.begin(sdChipSelect, SPI) && SD.cardType() != CARD_NONE && preparePhotoDirectory(SD)) {
        Serial.println("Photo storage: microSD.");
        return &SD;
    }
    SD.end();

    // Initialize erased flash only. Preserve data if an existing partition fails to mount.
    const bool flashMounted = LittleFS.begin(false, flashMount) ||
                              (flashPartitionIsBlank() && LittleFS.begin(true, flashMount));
    if (flashMounted && preparePhotoDirectory(LittleFS)) {
        Serial.println("Photo storage: onboard flash (LittleFS).");
        return &LittleFS;
    }
    Serial.println("ERROR Could not open photo storage.");
    return nullptr;
}

bool capturePhoto() {
    char path[sizeof("/DCIM/IMG_0000.JPG")];
    while (nextPhoto <= maxPhotoNumber) {
        snprintf(path, sizeof(path), "/DCIM/IMG_%04u.JPG", nextPhoto);
        if (!photoStorage->exists(path)) {
            break;
        }
        ++nextPhoto;
    }
    if (nextPhoto > maxPhotoNumber) {
        Serial.println("No free IMG_0001 through IMG_9999 filename.");
        return false;
    }

    // Give exposure time to settle, then discard the first queued frame.
    delay(250);
    if (camera_fb_t *queued = esp_camera_fb_get()) {
        esp_camera_fb_return(queued);
    } else {
        Serial.println("Camera did not return a frame.");
        return false;
    }
    camera_fb_t *frame = esp_camera_fb_get();
    if (!frame) {
        Serial.println("Photo capture failed.");
        return false;
    }

    const size_t size = frame->len;
    size_t written = 0;
    if (frame->format == PIXFORMAT_JPEG && size > 0) {
        File file = photoStorage->open(temporaryImage, FILE_WRITE);
        if (file) {
            written = file.write(frame->buf, size);
            file.close();
        }
    }
    esp_camera_fb_return(frame);

    if (size == 0 || written != size || !photoStorage->rename(temporaryImage, path)) {
        photoStorage->remove(temporaryImage);
        Serial.println("Photo was not saved. Check photo storage and free space.");
        return false;
    }
    ++nextPhoto;
    Serial.printf("Saved %s (%u bytes)\n", path, static_cast<unsigned>(size));
    return true;
}

void takePhoto() {
    if (!photoStorage || !setupCamera()) {
        Serial.println("ERROR Camera or photo storage unavailable.");
        return;
    }
    const bool saved = capturePhoto();
    const esp_err_t stopped = esp_camera_deinit();
    if (stopped != ESP_OK) {
        Serial.printf("ERROR Camera shutdown failed: 0x%X. Reset the board.\n",
                      static_cast<unsigned>(stopped));
        return;
    }
    Serial.println(saved ? "OK Camera stopped." : "ERROR Photo not saved; camera stopped.");
}

bool isPhotoFilename(const char *name) {
    return std::strlen(name) == 12 && std::strncmp(name, "IMG_", 4) == 0 &&
           std::strcmp(name + 8, ".JPG") == 0 &&
           std::all_of(name + 4, name + 8, [](char digit) { return digit >= '0' && digit <= '9'; });
}

void exportPhotos() {
    if (!photoStorage) {
        Serial.println("ERROR Photo storage unavailable.");
        return;
    }
    File directory = photoStorage->open(captureDirectory);
    if (!directory || !directory.isDirectory()) {
        Serial.println("ERROR Photo directory unavailable.");
        return;
    }
    Serial.println("CAMDEVICE EXPORT 1");
    uint8_t buffer[1024];
    for (File file = directory.openNextFile(); file; file = directory.openNextFile()) {
        const String name = file.name();
        if (file.isDirectory() || !isPhotoFilename(name.c_str()) || !file.size()) {
            continue;
        }
        const size_t size = file.size();
        Serial.printf("FILE %s %u\n", name.c_str(), static_cast<unsigned>(size));
        size_t remaining = size;
        while (remaining > 0) {
            const size_t count = file.read(buffer, min(remaining, sizeof(buffer)));
            if (!count) {
                // The host discards the incomplete file when its read times out.
                return;
            }
            if (Serial.write(buffer, count) != count) {
                return;
            }
            remaining -= count;
        }
    }
    Serial.println("END");
}

struct FlashCleanupResult {
    unsigned removed = 0;
    unsigned failed = 0;
};

bool clearPhotoDirectory(const char *directory, FlashCleanupResult &result) {
    DIR *entries = opendir(directory);
    if (!entries) {
        return errno == ENOENT;
    }

    // Collect filenames first so deleting entries cannot move the directory cursor.
    std::bitset<maxPhotoNumber + 1> photos;
    errno = 0;
    while (const dirent *entry = readdir(entries)) {
        if (entry->d_type == DT_REG && isPhotoFilename(entry->d_name)) {
            unsigned number = 0;
            for (const char *digit = entry->d_name + 4; digit != entry->d_name + 8; ++digit) {
                number = number * 10 + (*digit - '0');
            }
            photos.set(number);
        }
    }
    const bool readComplete = errno == 0;
    closedir(entries);
    if (!readComplete) {
        return false;
    }

    char path[sizeof(flashMount) + sizeof(captureDirectory) + sizeof("/IMG_0000.JPG")];
    for (unsigned number = 0; number <= maxPhotoNumber; ++number) {
        if (!photos.test(number)) {
            continue;
        }
        snprintf(path, sizeof(path), "%s/IMG_%04u.JPG", directory, number);
        if (unlink(path) == 0) {
            ++result.removed;
        } else {
            ++result.failed;
        }
    }
    return true;
}

void clearFlashPhotos() {
    // LittleFS may be unmounted when the camera is saving to microSD.
    const bool mountForCleanup = !esp_littlefs_mounted(flashPartition);
    if (mountForCleanup && !LittleFS.begin(false, flashMount)) {
        if (flashPartitionIsBlank()) {
            Serial.println("CAMDEVICE FLASH CLEARED 0 0");
        } else {
            Serial.println("ERROR Could not mount photo flash.");
        }
        return;
    }
    char directory[sizeof(flashMount) + sizeof(captureDirectory)];
    snprintf(directory, sizeof(directory), "%s%s", flashMount, captureDirectory);
    FlashCleanupResult result;
    const bool listed = clearPhotoDirectory(directory, result);
    if (mountForCleanup) {
        LittleFS.end();
    }
    if (!listed) {
        Serial.println("ERROR Could not read flash photo directory.");
        return;
    }
    if (photoStorage == &LittleFS) {
        nextPhoto = 1;
    }
    Serial.printf("CAMDEVICE FLASH CLEARED %u %u\n", result.removed, result.failed);
}

void handleSerial() {
    static char command[2];
    static size_t length = 0;
    while (Serial.available()) {
        const int character = Serial.read();
        if (character == '\r' || character == '\n') {
            const size_t count = length;
            length = 0;
            if (count != 2) {
                continue;
            }
            if (command[0] == 'p' && command[1] == 'z') {
                takePhoto();
            } else if (command[0] == 'd' && command[1] == 'c') {
                exportPhotos();
            } else if (command[0] == 'f' && command[1] == 'c') {
                Serial.println("CAMDEVICE FLASH CLEAR 1");
            } else if (command[0] == 'c' && command[1] == 'l') {
                clearFlashPhotos();
            } else if (command[0] == 'i' && command[1] == 'd') {
                Serial.println("CAMDEVICE READY 1");
            } else {
                Serial.println("ERROR Use pz or dc.");
            }
        } else if (length < sizeof(command)) {
            command[length++] = character;
        } else {
            length = sizeof(command) + 1;
        }
    }
}

bool shutterPressed() {
    const int reading = digitalRead(shutterPin);
    const uint32_t now = millis();
    if (reading != rawButton) {
        rawButton = reading;
        rawChangedAt = now;
    }
    if (rawButton == stableButton || now - rawChangedAt < debounceMs) {
        return false;
    }
    stableButton = rawButton;
    return stableButton == LOW;
}
}  // namespace

void setup() {
    Serial.begin(115200);
    pinMode(shutterPin, INPUT_PULLUP);
    rawButton = stableButton = digitalRead(shutterPin);
    rawChangedAt = millis();

    photoStorage = setupPhotoStorage();
    Serial.println("Ready. Send pz to take a photo or dc to export over USB.");
}

void loop() {
    if (shutterPressed()) {
        takePhoto();
    }
    handleSerial();
    delay(2);
}
