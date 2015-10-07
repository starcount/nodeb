#!/bin/bash

fatecho() {  echo -e '\E[31m' "\n$1\n" '\e[0m' ; }

DEBUG= # 'v' for verbose t?ar

export nbPort=80
export nbUser=node
export nbWeb=
export nbSsl=
export nbNoins=

proxy_sock=/var/run/proxy.sock
web_server_group=www-data

dir=`dirname $(readlink -f $0)`

while getopts "p:tu:w:sovn" opt; do
  case $opt in
    n)
      nbNoassets='--exclude=node_modules --exclude=bower_components --exclude=components'
      ;;
    u)
      nbUser=$OPTARG
      ;;
    o)
      nbNoins=1
      ;;
    p)
      nbPort=$OPTARG
      ;;
    s)
      nbSsl=1
      ;;
    t)
      [[ -e nodeb_templates ]] && {
        fatecho \"nodeb_templates\" exists, delete it first. Not executing. >&2
      } || {
        cp -a $dir/../templates nodeb_templates/
        echo nodeb_templates/ created.
      }
      exit 0
      ;;
    v)
     verbose=1
     ;;
    w)
     nbWeb=$OPTARG
     ;;
    \?)
      cat <<-EOH >&2

  Valid options:

  -n don't include node_modules/, bower_components/, components/ in the package
  -o don't generate nginx config for insecure (http) server
  -p <port to monitor> (default 80) 
  -s generate nginx config for secure (https) server
  -t copy templates to nodeb_templates/ for customization and exit
  -u <user to run processes as> (default "node")
  -v show generated files on stdout
  -w <production website address>. If given, nginx config files will be created

EOH
      exit 1
      ;;
  esac
done

pdir=$PWD

TDIR=`mktemp -d`
RDIR=`mktemp -d`

trap "rm -fr $TDIR $RDIR" SIGHUP SIGINT SIGTERM SIGQUIT EXIT

node -e '
  pkg = require("./package.json")

  console.log("set -a")
  console.log("Source=" + pkg.name)
  console.log("Package=" + pkg.name)
  console.log("Version=" + pkg.version)
  console.log("Priority=extra")
  console.log("Maintainer=\"" + pkg.author + "\"")
  console.log("Architecture=all")
  console.log("Depends=\"${nodejs:Depends}\"")
  console.log("Description=\"" + pkg.description + "\"")
  console.log("Exec=\"" + pkg.config.start + "\"")
    ' | { source /dev/stdin

if [ -z "$Exec" -o -z "$Package" ] ; then
  echo
  echo '*** Error: package.json must contain at least "name" and "config":{"start":...} values. ***' >&2
  echo
  exit 1
fi

export Command=${Exec%% *}
export CommandArgs=${Exec#* }

# some vars to preserve in nginx files

for keepit in uri is_args args host http_upgrade remote_addr proxy_add_x_forwarded_for ; do
  export $keepit=\$${keepit}
done

Name=node-$Package

[[ -d nodeb_templates ]] &&
  cd nodeb_templates ||
  cd $dir/../templates

[[ $nbWeb ]]   || rm -fr $RDIR/etc/nginx/
[[ $nbSsl ]]   || rm -fr $RDIR/etc/nginx/sites-available/node-$Package-ssl
[[ $nbNoins ]] && rm -fr $RDIR/etc/nginx/sites-available/node-$Package

for src in *; do
  dst=${src//,//}
  dst=${dst/PACKAGE/$Package}
  dstdir=`dirname $dst`

  mkdir -p $RDIR/$dstdir
  envsubst < $src > $RDIR/$dst
  [[ $verbose ]] && {
    echo -e '\E[37;44m'
    echo -e $dst '\E[0m'
    cat $RDIR/$dst
  }
done


cat > $TDIR/control <<EOD
Source: $Package
Package: $Package
Version: $Version
Priority:  extra
Maintainer: $Maintainer
Architecture: all
Depends: nodejs
Description: $Description
EOD

cat > $TDIR/postinst <<EOD
chown -R $nbUser /opt/$Package
adduser $nbUser $web_server_group

[ -d /opt/$Package/node_modules ] || {
  command -v npm >/dev/null 2>&1 || { 
    echo >&2 "I require npm but it's not installed.  Aborting."
    exit 1
  }
  echo "Running npm...."
  cd /opt/$Package
  sudo -H -u $nbUser npm i
}
echo "Starting $Name"
start $Name
EOD

[[ $nbSsl ]] &&
  cat >> $TDIR/postinst <<EOD

mkdir -p /opt/ssl/$Package
echo
echo Make sure you have you SSL files in place:
echo "    certificate in /opt/ssl/$Package/production.pem"
echo "    private key in /opt/ssl/$Package/production.key"
echo

EOD

[[ $nbWeb ]] &&
  cat >> $TDIR/postinst <<EOD

cd /etc/nginx/sites-enabled
ln -s -f ../sites-available/$Name .
ln -s ../sites-available/${Name}-ssl . 2>/dev/null

[ -d $proxy_sock ] || {
  mkdir $proxy_sock
  chown www-data:www-data $proxy_sock
}

chmod 3770 $proxy_sock

echo "Restarting nginx"
service nginx restart
EOD


cat > $TDIR/preinst <<EOD

dpkg -s nodejs >/dev/null 2>&1 || {
  echo
  echo /usr/bin/nodejs is required. Abort.
  echo
  exit 1
}

id $nbUser > /dev/null 2>&1 && {
  ln -f -s /usr/bin/nodejs /usr/bin/node
} || {
  echo
  echo Please create user "$nbUser" first.  Abort.
  echo
  exit 1
}
EOD

cat > $TDIR/prerm <<EOD
echo "Stopping $Name"
stop $Name
exit 0
EOD

cd $TDIR
tar -c${DEBUG}f control.tar *

cd $RDIR
tar -c${DEBUG}f $TDIR/data.tar *

cd $pdir
tar -C $pdir \
  --xform="s:^.:opt/$Package:" \
  --exclude-backups \
  --exclude=nodeb_templates \
  --exclude=*.deb  $nbNoassets \
  -r${DEBUG}f $TDIR/data.tar .

cd $TDIR
gzip control.tar
gzip data.tar

echo 2.0 > debian-binary

debfile=$pdir/$Package.deb
ar r$DEBUG $debfile debian-binary control.tar.gz data.tar.gz 2>/dev/null

fatecho "$debfile created."
}
