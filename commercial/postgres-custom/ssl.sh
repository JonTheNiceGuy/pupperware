#!/bin/sh
#
# Get a signed certificate for this host.
#
# Uses OpenSSL and curl directly to generate a new CSR and get it signed by the
# Puppet Server CA.
#
# Intended to be used in place of a full-blown puppet agent run that is solely
# for getting SSL certificates onto the host.
#
# Files will be placed in the same default directory location and structure
# that the puppet agent would put them, which is /etc/puppetlabs/puppet/ssl.
#
# The certname can be provided as the first argument to this script, or
# as the CERTNAME environment variable. If both are found, the argument
# takes precedence over the environment variable. If neither are found,
# the HOSTNAME will be used.
#
# Supports DNS alt names via the DNS_ALT_NAMES environment variable, which
# is a comma-separated string of names. The Puppet Server CA must be configured
# to allow subject alt names, by default it will reject certificate requests
# with them.
#
# Arguments:
#   $1  (Optional) Certname to use. Overrides the CERTNAME environment variable.
#                  If neither are set, the $HOSTNAME will be used.
#
# Optional environment variables:
#   CERTNAME               Certname to use, unless an argument is passed in
#   WAITFORCERT            Number of seconds to wait for certificate to be
#                          signed, defaults to 120
#   PUPPETSERVER_HOSTNAME  Hostname of Puppet Server CA, defaults to "puppet"
#   SSLDIR                 Root directory to write files to, defaults to
#                          "/etc/puppetlabs/puppet/ssl"
#   DNS_ALT_NAMES          Comma-separated string of DNS subject alternative
#                          names, defaults to none

msg() {
    echo "($0) $1"
}

error() {
    msg "Error: $1"
    exit 1
}

### Verify dependencies available
! command -v openssl > /dev/null && error "openssl not found on PATH"
! command -v curl > /dev/null && error "curl not found on PATH"

### Verify options are valid
CERTNAME="${1:-${CERTNAME:-${HOSTNAME}}}"
[ -z "${CERTNAME}" ] && error "certificate name must be non-empty value"
PUPPETSERVER_HOSTNAME="${PUPPETSERVER_HOSTNAME:-puppet}"
SSLDIR="${SSLDIR:-/etc/puppetlabs/puppet/ssl}"
WAITFORCERT=${WAITFORCERT:-120}
DNS_ALT_NAMES=${DNS_ALT_NAMES}

### Create directories and files
PUBKEYDIR="${SSLDIR}/public_keys"
PRIVKEYDIR="${SSLDIR}/private_keys"
CSRDIR="${SSLDIR}/certificate_requests"
CERTDIR="${SSLDIR}/certs"
mkdir -p "${SSLDIR}" "${PUBKEYDIR}" "${PRIVKEYDIR}" "${CSRDIR}" "${CERTDIR}"
PUBKEYFILE="${PUBKEYDIR}/${CERTNAME}.pem"
PRIVKEYFILE="${PRIVKEYDIR}/${CERTNAME}.pem"
CSRFILE="${CSRDIR}/${CERTNAME}.pem"
CERTFILE="${CERTDIR}/${CERTNAME}.pem"
CACERTFILE="${CERTDIR}/ca.pem"
CRLFILE="${SSLDIR}/crl.pem"

CA="https://${PUPPETSERVER_HOSTNAME}:8140/puppet-ca/v1"
CERTSUBJECT="/CN=${CERTNAME}"
CERTHEADER="-----BEGIN CERTIFICATE-----"
CURLFLAGS="--silent --show-error --cacert ${CACERTFILE} --retry 5 --retry-connrefused --retry-delay 2"

### Handle certificate extensions
# NOTE If we want to expand support for more extensions, it would be better
# to define them in a .conf file rather than directly on the CLI.
# That would also work on older versions of openssl that don't support
# the `-addext` flag.
# For now, we explicitly handle DNS alt names because it's simpler.
CERTEXTENSIONS=""
if [ -n "${DNS_ALT_NAMES}" ]; then
    names=""
    first=true
    for name in $(echo "${DNS_ALT_NAMES}" | tr "," " "); do
        if $first; then
            first=false
            names="DNS:${name}"
        else
            names="${names},DNS:${name}"
        fi
    done
    CERTEXTENSIONS="-addext subjectAltName=${names}"
fi

### Print configuration for troubleshooting
msg "Using configuration values:"
msg "* CERTNAME: '${CERTNAME}' (${CERTSUBJECT})"
msg "* DNS_ALT_NAMES: '${DNS_ALT_NAMES}'"
msg "* CA: '${CA}'"
msg "* SSLDIR: '${SSLDIR}'"
msg "* WAITFORCERT: '${WAITFORCERT}' seconds"

### Get the CA certificate for use with subsequent requests
### Fail-fast if curl errors or the CA certificate can't be parsed
curl --insecure --silent --show-error --output "${CACERTFILE}" --retry 5 --retry-connrefused --retry-delay 2 "${CA}/certificate/ca"
if [ $? -ne 0 ]; then
    error "cannot reach CA host '${PUPPETSERVER_HOSTNAME}'"
elif ! openssl x509 -subject -issuer -noout -in "${CACERTFILE}"; then
    error "invalid CA certificate"
fi

### Get the CRL from the CA for use with client-side validation
curl ${CURLFLAGS} --output "${CRLFILE}" "${CA}/certificate_revocation_list/ca"
if ! openssl crl -text -noout -in "${CRLFILE}" > /dev/null; then
    error "invalid CRL"
fi

### Check the CA does not already have a signed certificate for this host
output="$(curl ${CURLFLAGS} "${CA}/certificate/${CERTNAME}")"
if [ "$(echo "${output}" | head -1)" = "${CERTHEADER}" ]; then
    error "CA already has signed certificate for '${CERTNAME}'"
fi

### Generate keys and CSR for this host
[ -s "${PRIVKEYFILE}" ] && error "private key '${PRIVKEYFILE}' already exists"
[ -s "${PUBKEYFILE}" ] && error "public key '${PUBKEYFILE}' already exists"
[ -s "${CSRFILE}" ] && error "certificate request '${CSRFILE}' already exists"
openssl genrsa -out "${PRIVKEYFILE}" 4096
openssl rsa -in "${PRIVKEYFILE}" -pubout -out "${PUBKEYFILE}"
openssl req -new -key "${PRIVKEYFILE}" -out "${CSRFILE}" -subj "${CERTSUBJECT}" ${CERTEXTENSIONS}

### Submit CSR and fail gracefully on certain error conditions
output="$(curl ${CURLFLAGS} -X PUT -H "Content-Type: text/plain" \
               --data-binary "@${CSRFILE}" "${CA}/certificate_request/${CERTNAME}")"
if [ -n "${output}" ]; then
    cert_already_exists="${CERTNAME} already has a requested certificate; ignoring certificate request"
    altnames_disallowed="CSR '${CERTNAME}' contains subject alternative names*which are disallowed*"
    case "${output}" in
        $cert_already_exists) error "unsigned CSR for '${CERTNAME}' already exists on CA" ;;
        $altnames_disallowed) error "DNS Alt Names not allowed by the CA" ;;
        *) msg "[WARNING] CSR response: ${output}" ;;
    esac
fi

### Retrieve signed certificate; wait and try again with a timeout
sleeptime=10
timewaited=0
cert="$(curl ${CURLFLAGS} "${CA}/certificate/${CERTNAME}")"
while [ "$(echo "${cert}" | head -1)" != "${CERTHEADER}" ]; do
    [ ${timewaited} -ge ${WAITFORCERT} ] && \
        error "timed-out waiting for certificate to be signed"
    msg "Waiting for certificate to be signed..."
    sleep ${sleeptime}
    timewaited=$((${timewaited}+${sleeptime}))
    cert="$(curl ${CURLFLAGS} "${CA}/certificate/${CERTNAME}")"
done
echo "${cert}" > "${CERTFILE}"

### Verify we got a signed certificate
if [ -f "${CERTFILE}" ] && [ "$(head -1 "${CERTFILE}")" = "${CERTHEADER}" ]; then
    if openssl x509 -subject -issuer -noout -in "${CERTFILE}"; then
        msg "Successfully signed certificate '${CERTFILE}'"
    else
        error "invalid signed certificate '${CERTFILE}'"
    fi
else
    error "failed to get signed certificate for '${CERTNAME}'"
fi
