FROM debian:stretch
#FROM phusion/baseimage:master
LABEL maintainer="digitallibrary@nitc.ac.in"

RUN    apt update \
    && apt install -y \
            wget \
            supervisor \
            apache2 \
            gnupg2 \
            apt-transport-https \
    && apt clean

ARG KOHA_VERSION=20.11
ARG PKG_URL=https://debian.koha-community.org/koha

RUN if [ "${PKG_URL}" = "https://debian.koha-community.org/koha" ]; then \
        wget -q -O- https://debian.koha-community.org/koha/gpg.asc | apt-key add -; \
    fi

RUN echo "deb ${PKG_URL} ${KOHA_VERSION} main" | tee /etc/apt/sources.list.d/koha.list

# Install Koha
RUN    apt update \
    && apt install -y koha-common \
    && apt clean

RUN    a2enmod rewrite \
           headers \
           proxy_http \
           cgi \
    && a2dissite 000-default \
    && echo "Listen 8080\nListen 8081" > /etc/apache2/ports.conf

RUN mkdir /docker

COPY run.sh /docker/run.sh
COPY templates /docker/templates

WORKDIR /docker

EXPOSE 8080 8081

#CMD ["/sbin/my_init"]
CMD [ "./run.sh" ]
