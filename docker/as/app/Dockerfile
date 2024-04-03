FROM ubuntu:22.04

MAINTAINER Blake Graham-Henderson <blake@mobiusconsortium.org>

ARG MYSQLJ_VERSION=${MYSQLJ_VERSION}
ARG ASHOME=${ASHOME}
ARG ASUSER=${ASUSER}

ARG USER_ID=1200
ARG GROUP_ID=1200

# credits: https://github.com/archivesspace/archivesspace/blob/master/docker-startup.sh
# credits: https://github.com/umd-lib/aspace-docker/blob/develop/archivesspace/Dockerfile
# credits: https://github.com/alexchanwk/docker-archivesspace/blob/master/Dockerfile
# credits: https://github.com/anarchivist/docker-archivesspace/blob/master/Dockerfile
# credits: https://github.com/Einsteinish/Docker-compose-Nginx-Reverse-Proxy-II
# credits: https://gist.github.com/AustinTSchaffer/4f2a3ad4dd27097ed8bf25be4f12453b

# Expose the application's ports:
# 8080: Staff UI
# 8081: Public UI
# 8082: OAI-PMH
# 8089: Backend API
# 8090: Solr

EXPOSE 8089 8080 8081 8082 8090 8091
EXPOSE 22 10050


ENV DEBIAN_FRONTEND noninteractive
ENV TZ=America/Chicago
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone
RUN apt-get update && apt-get install -y --no-install-recommends apt-utils
RUN apt-get install -y wget curl unzip zip vim net-tools procps psmisc lsb-release gnupg sudo sendmail screen less tzdata git lsof
RUN dpkg-reconfigure --frontend noninteractive tzdata
RUN wget https://repo.mysql.com/mysql-apt-config_0.8.29-1_all.deb && \
    dpkg -i mysql-apt-config_0.8.29-1_all.deb && apt-get update && \
    apt-get install -y mysql-client && \
    groupadd -g ${GROUP_ID} archivesspace && \
    useradd -m -d ${ASHOME} -s /bin/bash -u ${USER_ID} -g ${GROUP_ID} -G sudo archivesspace && \
    echo 'archivesspace ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers.d/90-archivesspace

WORKDIR $ASHOME

# copy build context to workdir /home/archivesspace
COPY . . 

RUN chown -R ${ASUSER}:${ASUSER} ${ASHOME} 

USER $ASUSER

#HEALTHCHECK --interval=1m --timeout=30s --start-period=15m --retries=5 \
#        CMD curl -f http://localhost:8089/ || exit 1

ENTRYPOINT ["/bin/sleep","infinity"]

