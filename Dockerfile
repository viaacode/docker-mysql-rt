# This container inherits from https://github.com/docker-library/mysql
# It recovers a mysql LVM snapshot from the backup system 
# performs roll forward recovery and runs consistency checks 

FROM mysql:5.5
MAINTAINER Herwig Bogaert

ARG RecoverySocketGid=4

RUN apt-get update && apt-get install -y file socat && rm -rf /var/lib/apt/lists/*

# Grant the mysql user permission to manipulate the recovered files
RUN usermod -G $RecoverySocketGid mysql
ENV MYSQL_RANDOM_ROOT_PASSWORD true

COPY show_dbs.sql /docker-entrypoint-initdb.d/10-show_dbs.sql

COPY recover.sh /usr/local/bin/
COPY load.sh /usr/local/bin/
COPY recoverytestuser.sh /usr/local/bin/

ENV RECOVERY_AREA /recovery_area
ENV RECOVERY_SOCKET "unix:/recovery_socket"
