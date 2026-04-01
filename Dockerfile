# =============================================================================
# trunk-recorder — Pre-built image with all common plugins
# =============================================================================
# Plugins included:
#   mqtt_status     (TrunkRecorder/tr-plugin-mqtt)   — call/unit/recorder events
#   mqtt_dvcf       (trunk-reporter/tr-plugin-dvcf)  — DVCF writer + MQTT publisher
#   mqtt_avcf       (trunk-reporter/tr-plugin-avcf)  — AVCF writer + MQTT publisher
#   symbolstream    (trunk-reporter/symbolstream)     — live codec frame streaming
#   simplestream    (upstream, patched)               — audio streaming
#   openmhz_uploader  (upstream)                      — OpenMHz upload
#   broadcastify_uploader (upstream)                  — Broadcastify upload
#   unit_script     (upstream)                        — custom unit event scripts
#
# Usage:
#   docker run -v ./config.json:/app/config.json \
#              -v ./audio:/app/audio \
#              --privileged --device /dev/bus/usb:/dev/bus/usb \
#              ghcr.io/trunk-reporter/trunk-recorder:latest
# =============================================================================

FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get -y upgrade && \
    apt-get install --no-install-recommends -y \
        build-essential ca-certificates cmake curl git \
        gnuradio-dev gr-osmosdr \
        libosmosdr-dev libairspy-dev libairspyhf-dev libbladerf-dev \
        libboost-all-dev libcurl4-openssl-dev libfreesrp-dev \
        libgmp-dev libhackrf-dev libmirisdr-dev liborc-0.4-dev \
        libpthread-stubs0-dev librtlsdr-dev libsndfile1-dev \
        libsoapysdr-dev libssl-dev libuhd-dev \
        libusb-dev libusb-1.0-0-dev libxtrx-dev \
        pkg-config wget python3-six ffmpeg && \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Paho MQTT (required by mqtt_status + mqtt_dvcf + mqtt_avcf)
# ---------------------------------------------------------------------------
WORKDIR /deps

RUN git clone --depth 1 --branch v1.3.13 https://github.com/eclipse/paho.mqtt.c.git && \
    cd paho.mqtt.c && \
    cmake -Bbuild -DPAHO_WITH_SSL=ON -DPAHO_BUILD_SHARED=ON -DPAHO_BUILD_STATIC=OFF && \
    cmake --build build -j$(nproc) && cmake --install build

RUN git clone --depth 1 --branch v1.4.1 https://github.com/eclipse/paho.mqtt.cpp.git && \
    cd paho.mqtt.cpp && \
    cmake -Bbuild -DPAHO_WITH_SSL=ON -DPAHO_BUILD_SHARED=ON -DPAHO_BUILD_STATIC=OFF && \
    cmake --build build -j$(nproc) && cmake --install build

RUN ldconfig

# ---------------------------------------------------------------------------
# Clone upstream trunk-recorder
# ---------------------------------------------------------------------------
WORKDIR /src
RUN git clone --depth 1 https://github.com/TrunkRecorder/trunk-recorder.git .

# Apply pending fix: simplestream dangling pointer (PR #1107)
COPY patches/simplestream-dangling-pointer.patch /tmp/
RUN patch -p1 < /tmp/simplestream-dangling-pointer.patch

# Enable simplestream plugin (commented out in upstream CMakeLists.txt)
RUN sed -i 's|#add_subdirectory(plugins/simplestream)|add_subdirectory(plugins/simplestream)|' CMakeLists.txt

# ---------------------------------------------------------------------------
# Add user_plugins
# ---------------------------------------------------------------------------
RUN mkdir -p user_plugins

# Standard MQTT status plugin
RUN git clone --depth 1 https://github.com/TrunkRecorder/tr-plugin-mqtt user_plugins/mqtt_status

# DVCF writer + MQTT publisher (IMBE-ASR integration)
RUN git clone --depth 1 https://github.com/trunk-reporter/tr-plugin-dvcf user_plugins/mqtt_dvcf

# AVCF writer + MQTT publisher (analog call capture)
RUN git clone --depth 1 https://github.com/trunk-reporter/tr-plugin-avcf user_plugins/mqtt_avcf

# Live codec frame streaming
RUN git clone --depth 1 https://github.com/trunk-reporter/symbolstream user_plugins/symbolstream

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
RUN cmake -Bbuild -DUSE_LOCAL_PLUGINS=ON && \
    cmake --build build -j$(nproc) && \
    cmake --install build --prefix /newroot/usr/local

# =============================================================================
# Runtime stage
# =============================================================================
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get -y upgrade && \
    apt-get install --no-install-recommends -y \
        ca-certificates curl wget sox fdkaac ffmpeg \
        gr-funcube gr-iqbal \
        libboost-log1.83.0 libboost-chrono1.83.0t64 \
        libgnuradio-digital3.10.9t64 libgnuradio-analog3.10.9t64 \
        libgnuradio-filter3.10.9t64 libgnuradio-network3.10.9t64 \
        libgnuradio-uhd3.10.9t64 libgnuradio-osmosdr0.2.0t64 \
        libsoapysdr0.8 soapysdr0.8-module-all \
        libairspyhf1 libfreesrp0 librtlsdr2 libxtrx0 \
        libcurl4t64 libssl3t64 && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /newroot /
COPY --from=builder /usr/local/lib/libpaho* /usr/local/lib/
COPY --from=builder /usr/local/lib/trunk-recorder/ /usr/local/lib/trunk-recorder/

RUN mkdir -p /etc/gnuradio/conf.d/ && \
    echo 'log_level = info' >> /etc/gnuradio/conf.d/gnuradio-runtime.conf && \
    ldconfig

WORKDIR /app
ENV HOME=/tmp

LABEL org.opencontainers.image.source="https://github.com/trunk-reporter/tr-docker"
LABEL org.opencontainers.image.description="Trunk Recorder with mqtt_status, mqtt_dvcf, mqtt_avcf, symbolstream, simplestream, openmhz, broadcastify, unit_script"

CMD ["trunk-recorder", "--config=/app/config.json"]
