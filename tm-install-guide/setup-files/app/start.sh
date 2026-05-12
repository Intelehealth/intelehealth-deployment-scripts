#!/bin/bash
set -e

# Set JVM options for OpenMRS
export CATALINA_OPTS="\
  -Xms512m \
  -Xmx1024m \
  -XX:MaxPermSize=256m \
  -DOPENMRS_APPLICATION_DATA_DIRECTORY=/opt/openmrs/data \
  -Dfile.encoding=UTF-8"

exec $CATALINA_HOME/bin/catalina.sh run
