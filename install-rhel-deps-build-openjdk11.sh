#!/bin/bash
set -e

# Determine platform name. Currently supported:
#
# x86_64 => x64_linux
# aarch64 => aarch64_linux
#
platform_name() {
  arch=$(uname -m)
  case $arch in
  x86_64)
    echo "x64_linux"
    ;;
  aarch64)
    echo "aarch64_linux"
    ;;
  *)
    echo "Unsupported platform '$arch'" 1>&2
    exit 1
    ;;
  esac
}

BRS_FILE=openjdk_build_deps.txt
BUILD_SCRIPT=build-openjdk11.sh

cat > $BRS_FILE <<EOF
autoconf
automake
alsa-lib-devel
binutils
cups-devel
fontconfig
freetype-devel
giflib-devel
gcc-c++
gtk2-devel
libjpeg-devel
libpng-devel
libxslt
libX11-devel
libXi-devel
libXinerama-devel
libXt-devel
libXtst-devel
pkgconfig
xorg-x11-proto-devel
zip
unzip
java-1.8.0-openjdk-devel
openssl
mercurial
wget
patch
gzip
tar
EOF

# Download and install boot JDK
#
# Originally boot-strapped with build-openjdk9.sh and build-openjdk10.sh
# For simplicity download a suitable boot JDK from AdoptOpenJDK.
pushd /opt
wget -O jdk-11.0.3_7.tar.gz "https://github.com/AdoptOpenJDK/openjdk11-binaries/releases/download/jdk-11.0.3%2B7/OpenJDK11U-jdk_$(platform_name)_hotspot_11.0.3_7.tar.gz"
tar -xf jdk-11.0.3_7.tar.gz
/opt/jdk-11.0.3+7/bin/java -version
popd

yum -y install $(echo $(cat $BRS_FILE))

# On some build hosts available disk size of /home
# is insufficient for building OpenJDK in release and
# slowdebug configurations. Be sure to bind-mount
# an appropriate slice of / for the build to succeed.
THRESHOLD_DISK_SIZE="20"
AVAIL_HOME="$(echo $(df -P --block-size=G /home | tail -n1 | awk '{print $4}' | sed 's/G//g'))"
AVAIL_OPT="$(echo $(df -P --block-size=G /opt | tail -n1 | awk '{print $4}' | sed 's/G//g'))"
if [ ${AVAIL_HOME} -lt ${THRESHOLD_DISK_SIZE} ]; then
  # Some diagnostic output
  df -P -h
  if [ ${AVAIL_OPT} -lt ${THRESHOLD_DISK_SIZE} ]; then
    # Nothing we can do, the build host seems not suitable
    echo "Neither /home nor /opt have sufficient disk space available. This is an error." 1>&2
    exit 1
  fi
  # Preconditions met. Bind mount a slice of /opt
  if [ ! -e /opt/openjdk ]; then
    mkdir /opt/openjdk
  fi
  if [ ! -e /home/openjdk ]; then
    mkdir /home/openjdk
  fi
  echo -n "Bind-mounting /opt/openjdk (Avail: ${AVAIL_OPT}G) to "
  echo "/home/openjdk (Avail: ${AVAIL_HOME}G) for disk space reasons."
  mount -o bind /opt/openjdk /home/openjdk
else
  echo "Disk space of /home seems sufficient: Avail: ${AVAIL_OPT}G"
fi
useradd openjdk

# Note: platform_name intentionally not escaped
cat > $BUILD_SCRIPT <<EOF
#!/bin/bash
set -e

UPDATE="11.0.4"
BUILD=11
NAME="openjdk-\${UPDATE}+\${BUILD}"
JRE_NAME="\${NAME}-jre"
TARBALL_BASE_NAME="OpenJDK11U"
EA_SUFFIX=""
PLATFORM="$(platform_name)"
TARBALL_VERSION="\${UPDATE}_\${BUILD}\${EA_SUFFIX}"
PLATFORM_VERSION="\${PLATFORM}_\${TARBALL_VERSION}"
TARBALL_NAME="\${TARBALL_BASE_NAME}-jdk_\${PLATFORM_VERSION}"
TARBALL_NAME_JRE="\${TARBALL_BASE_NAME}-jre_\${PLATFORM_VERSION}"
SOURCE_NAME="\${TARBALL_BASE_NAME}-sources_\${TARBALL_VERSION}"
# Release string for the vendor. Use the GA date.
VENDOR="18.9"

CLONE_URL=https://hg.openjdk.java.net/jdk-updates/jdk11u
TAG="jdk-\${UPDATE}+\${BUILD}"

clone() {
  url=\$1
  tag=\$2
  targetdir=\$3
  if [ -d \$targetdir ]; then
    echo "Target directory \$targetdir already exists. Skipping clone"
    return
  fi
  hg clone -u \$tag \$url \$targetdir
}

build() {
  # On some systems the per user process limit is set too low
  # by default (e.g. 1024). This may make the build fail on
  # systems with many cores (e.g. 64). Raise the limit to 1/2
  # of the maximum amount of threads allowed by the kernel.
  if [ -e /proc/sys/kernel/threads-max ]; then
    ulimit -u \$(( \$(cat /proc/sys/kernel/threads-max) / 2))
  fi

  rm -rf build

  # Add patch to be able to build on EL 6
  wget https://bugs.openjdk.java.net/secure/attachment/81704/JDK-8219879.jdk11.export.patch
  patch -p1 < JDK-8219879.jdk11.export.patch

  # Create a source tarball archive corresponding to the
  # binary build
  tar -c -z -f ../\${SOURCE_NAME}.tar.gz --transform "s|^|\${NAME}-sources/|" --exclude-vcs --exclude='**.patch*' --exclude='overall-build.log' .

  VERSION_PRE=""
  if [ "\${EA_SUFFIX}_" != "_" ]; then
    VERSION_PRE="ea"
  fi

  for debug in release slowdebug; do
    bash configure \
       --with-boot-jdk="/opt/jdk-11.0.3+7/" \
       --with-debug-level="\$debug" \
       --with-conf-name="\$debug" \
       --enable-unlimited-crypto \
       --with-version-build=\$BUILD \
       --with-version-pre="\$VERSION_PRE" \
       --with-version-opt="" \
       --with-vendor-version-string="\$VENDOR" \
       --with-native-debug-symbols=external \
       --disable-warnings-as-errors
    targets="bootcycle-images legacy-images"
    if [ "\${debug}_" == "slowdebug_" ]; then
      targets="images"
    fi
    make LOG=debug CONF=\$debug \$targets
    # Package it up
    pushd build/\$debug/images
      if [ "\${debug}_" == "slowdebug_" ]; then
	NAME="\$NAME-\$debug"
	TARBALL_NAME="\$TARBALL_NAME-\$debug"
      fi
      mv jdk \$NAME    
      tar -c -f \${TARBALL_NAME}.tar \$NAME --exclude='**.debuginfo'
      gzip \${TARBALL_NAME}.tar
      tar -c -f \${TARBALL_NAME}-debuginfo.tar \$(find \${NAME}/ -name \*.debuginfo)
      gzip \${TARBALL_NAME}-debuginfo.tar
      mv \$NAME jdk
      # JRE package produced via legacy-images (release only)
      if [ "\${debug}_" == "release_" ]; then
        mv jre \$JRE_NAME
        tar -c -f \${TARBALL_NAME_JRE}.tar \$JRE_NAME --exclude='**.debuginfo'
        gzip \${TARBALL_NAME_JRE}.tar
        tar -c -f \${TARBALL_NAME_JRE}-debuginfo.tar \$(find \${JRE_NAME}/ -name \*.debuginfo)
        gzip \${TARBALL_NAME_JRE}-debuginfo.tar
        mv \$JRE_NAME jre
      fi
    popd
  done
  mv ../\${SOURCE_NAME}.tar.gz build/

  find \$(pwd)/build -name \*.tar.gz
}

TARGET_FOLDER="jdk11u"
clone \$CLONE_URL \$TAG \$TARGET_FOLDER
pushd \$TARGET_FOLDER
  build 2>&1 | tee overall-build.log
popd
ALL_ARTEFACTS="\$NAME\$EA_SUFFIX-$(platform_name)-all-artefacts.tar"
tar -c -f \$ALL_ARTEFACTS --transform "s|^\$TARGET_FOLDER/|\$NAME\$EA_SUFFIX-all-artefacts/$(platform_name)/|g" \$(echo \$(find \$TARGET_FOLDER/build -name \*.tar.gz) \$TARGET_FOLDER/overall-build.log)
gzip \$ALL_ARTEFACTS
ls -lh \$(pwd)/*.tar.gz
EOF

cp $BUILD_SCRIPT /home/openjdk
chown -R openjdk /home/openjdk

# Drop privs and perform build
su -c "bash $BUILD_SCRIPT" - openjdk
