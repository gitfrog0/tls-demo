#!/bin/bash

set -e

if [ -z "$1" ]; then
  echo "FQDN not supplied"
  exit 1
fi

FQDN=$1
VALIDITY_IN_DAYS=3650
TRUSTSTORE_WORKING_DIRECTORY="truststore"
CA_KEY_FILE="ca-key.pem"
CA_CERT_FILE="ca.crt"
DEFAULT_TRUSTSTORE_FILENAME="truststore.jks"
KEYSTORE_WORKING_DIRECTORY="keystore"
PRIVATE_KEY_FILE="$FQDN-key.pem"
KEYSTORE_SIGNED_CERT="$FQDN-signed.crt"
KEYSTORE_SIGN_REQUEST="$FQDN.csr"
KEYSTORE_FILENAME="$FQDN-keystore.jks"
OPENSSL_EXT_CONFIG="$FQDN.cnf"
KEYSTORE_P12_FILE="$FQDN.p12"

COUNTRY="US"
STATE="CA"
OU="CONFLUENT"
CN=$FQDN
CA_CN="certificate-authority"
LOCATION="Atlantis"
PASS="secret"

function file_exists_and_exit() {
  echo "'$1' cannot exist. Move or delete it before"
  echo "re-running this script."
  exit 1
}

if [ -e "$PRIVATE_KEY_FILE" ]; then
  file_exists_and_exit $PRIVATE_KEY_FILE
fi

if [ -e "$KEYSTORE_SIGNED_CERT" ]; then
  file_exists_and_exit $KEYSTORE_SIGNED_CERT
fi

if [ -e "$KEYSTORE_SIGN_REQUEST" ]; then
  file_exists_and_exit $KEYSTORE_SIGN_REQUEST
fi

if [ -e "$KEYSTORE_FILENAME" ]; then
  file_exists_and_exit $KEYSTORE_FILENAME
fi

if [ -e "$OPENSSL_EXT_CONFIG" ]; then
  file_exists_and_exit $OPENSSL_EXT_CONFIG
fi

if [ -e "$KEYSTORE_P12_FILE" ]; then
  file_exists_and_exit $KEYSTORE_P12_FILE
fi

echo "Welcome to the Kafka SSL keystore and trust store generator script."

if [ ! -e "$TRUSTSTORE_WORKING_DIRECTORY" ]; then
  mkdir $TRUSTSTORE_WORKING_DIRECTORY
fi

if [ ! -e "$TRUSTSTORE_WORKING_DIRECTORY/$CA_KEY_FILE" ]; then
  echo
  echo "OK, we'll generate a trust store and associated private key."
  echo
  echo "First, the public/private keypair."
  echo

  openssl req -new -x509 -newkey rsa:2048 -keyout $TRUSTSTORE_WORKING_DIRECTORY/$CA_KEY_FILE \
    -out $TRUSTSTORE_WORKING_DIRECTORY/$CA_CERT_FILE -days $VALIDITY_IN_DAYS -nodes \
    -subj "/C=$COUNTRY/ST=$STATE/L=$LOCATION/O=$OU/CN=$CA_CN"

  echo
  echo "Two files were created:"
  echo " - $TRUSTSTORE_WORKING_DIRECTORY/$CA_KEY_FILE -- the private key used later to"
  echo "   sign certificates"
  echo " - $TRUSTSTORE_WORKING_DIRECTORY/$CA_CERT_FILE -- the self-signed certificate that will be"
  echo "   stored in the trust store in a moment and serve as the certificate"
  echo "   authority (CA)."
fi

if [ ! -e "$TRUSTSTORE_WORKING_DIRECTORY/$DEFAULT_TRUSTSTORE_FILENAME" ]; then

  echo
  echo "Now the trust store will be generated from the certificate."
  echo

  keytool -keystore $TRUSTSTORE_WORKING_DIRECTORY/$DEFAULT_TRUSTSTORE_FILENAME \
    -alias CARoot -import -file $TRUSTSTORE_WORKING_DIRECTORY/$CA_CERT_FILE \
    -noprompt -dname "C=$COUNTRY, ST=$STATE, L=$LOCATION, O=$OU, CN=$CA_CN" -keypass $PASS -storepass $PASS \
    -storetype PKCS12


  echo
  echo "$TRUSTSTORE_WORKING_DIRECTORY/$DEFAULT_TRUSTSTORE_FILENAME was created."

  echo
  echo "Continuing with:"
  echo " - trust store file:        $TRUSTSTORE_WORKING_DIRECTORY/$DEFAULT_TRUSTSTORE_FILENAME"
  echo " - trust store private key: $TRUSTSTORE_WORKING_DIRECTORY/$CA_KEY_FILE"

fi

if [ ! -e "$KEYSTORE_WORKING_DIRECTORY" ]; then
  mkdir $KEYSTORE_WORKING_DIRECTORY
fi

echo
echo "Create the public/private keypair which includes a certification signing request."
echo
openssl req -new -newkey rsa:2048 -nodes -keyout $KEYSTORE_WORKING_DIRECTORY/$PRIVATE_KEY_FILE \
  -out $KEYSTORE_WORKING_DIRECTORY/$KEYSTORE_SIGN_REQUEST \
  -subj "/C=$COUNTRY/ST=$STATE/L=$LOCATION/O=$OU/CN=$CN"
  
echo
echo "Now create the Openssl extension configuration file to include Subject Alternate Name."
echo

cat > $KEYSTORE_WORKING_DIRECTORY/$OPENSSL_EXT_CONFIG <<EOF
[v3_ca]
extendedKeyUsage = serverAuth , clientAuth
subjectAltName = DNS:$FQDN
EOF

echo
echo "Now the trust store's private key (CA) will sign the certificate."
echo
openssl x509 -req -CA $TRUSTSTORE_WORKING_DIRECTORY/$CA_CERT_FILE -CAkey $TRUSTSTORE_WORKING_DIRECTORY/$CA_KEY_FILE \
  -in $KEYSTORE_WORKING_DIRECTORY/$KEYSTORE_SIGN_REQUEST -out $KEYSTORE_WORKING_DIRECTORY/$KEYSTORE_SIGNED_CERT \
  -days $VALIDITY_IN_DAYS -CAcreateserial -extfile $KEYSTORE_WORKING_DIRECTORY/$OPENSSL_EXT_CONFIG -extensions v3_ca

echo
echo "Now create the certificate chain with the CA cert and the newly signed certificate."
echo
openssl pkcs12 -export -in $KEYSTORE_WORKING_DIRECTORY/$KEYSTORE_SIGNED_CERT -inkey $KEYSTORE_WORKING_DIRECTORY/$PRIVATE_KEY_FILE \
  -chain -CAfile $TRUSTSTORE_WORKING_DIRECTORY/$CA_CERT_FILE -name "localhost" -out $KEYSTORE_WORKING_DIRECTORY/$KEYSTORE_P12_FILE -password pass:$PASS

echo
echo "Now, a keystore will be generated. Each broker and logical client needs its own"
echo "keystore. This script will create only one keystore. Run this script multiple"
echo "times for multiple keystores."
echo
echo "     NOTE: currently in Kafka, the Common Name (CN) does not need to be the FQDN of"
echo "           this host. However, at some point, this may change. As such, make the CN"
echo "           the FQDN. Some operating systems call the CN prompt 'first / last name'"

# To learn more about CNs and FQDNs, read:
# https://docs.oracle.com/javase/7/docs/api/javax/net/ssl/X509ExtendedTrustManager.html

keytool -importkeystore -deststorepass $PASS -destkeystore $KEYSTORE_WORKING_DIRECTORY/$KEYSTORE_FILENAME \
    -srckeystore $KEYSTORE_WORKING_DIRECTORY/$KEYSTORE_P12_FILE \
    -deststoretype PKCS12  \
    -srcstoretype PKCS12 \
    -noprompt \
    -srcstorepass $PASS

echo
echo "'$KEYSTORE_WORKING_DIRECTORY/$KEYSTORE_FILENAME' now contains a key pair and a"
echo "self-signed certificate. Again, this keystore can only be used for one broker or"
echo "one logical client. Other brokers or clients need to generate their own keystores."

echo
echo "All done!"
echo
echo "Deleting intermediate files. They are:"
echo " - '$KEYSTORE_WORKING_DIRECTORY/$KEYSTORE_SIGN_REQUEST': the keystore's certificate signing request"
echo "   (that was fulfilled)"
echo " - '$KEYSTORE_WORKING_DIRECTORY/$OPENSSL_EXT_CONFIG': the openssl extensions configuration"

rm $KEYSTORE_WORKING_DIRECTORY/$KEYSTORE_SIGN_REQUEST
rm $KEYSTORE_WORKING_DIRECTORY/$OPENSSL_EXT_CONFIG