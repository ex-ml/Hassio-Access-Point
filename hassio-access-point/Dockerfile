ARG BUILD_FROM
FROM $BUILD_FROM

MAINTAINER ex-ml <ex_ml@sent.com>

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV LANG C.UTF-8

RUN apk update && \
apk add --no-cache bash iw hostapd networkmanager networkmanager-cli net-tools sudo dnsmasq iptables && \
rm -rf /var/cache/apk/*

COPY hostapd.conf /
COPY dnsmasq.conf /

COPY run.sh /
RUN chmod a+x /run.sh

CMD [ "/run.sh" ]
