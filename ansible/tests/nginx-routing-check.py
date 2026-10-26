#!/usr/bin/env python3
"""Compare direct backend TLS with central ingress, without application credentials."""
import argparse
import hashlib
import http.client
import json
from pathlib import Path
import socket
import ssl


def leaf(address, port, hostname, context, source_address=None):
    source = (source_address, 0) if source_address else None
    with socket.create_connection((address, port), timeout=10, source_address=source) as connection:
        with context.wrap_socket(connection, server_hostname=hostname) as secured:
            return hashlib.sha256(secured.getpeercert(binary_form=True)).hexdigest()


def assert_handshake_rejected(address, hostname, source_address=None):
    # A hostname mismatch must not count as rejection by the proxy. A successful
    # handshake with *any* certificate here is a routing/access-policy failure.
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    try:
        leaf(address, 443, hostname, context, source_address)
    except (ssl.SSLError, ConnectionResetError):
        return
    raise RuntimeError(f"TLS handshake unexpectedly accepted for {hostname}")


def http_result(address, port, hostname, path="/.well-known/acme-challenge/lab-ingress-probe"):
    connection = http.client.HTTPConnection(address, port, timeout=10)
    try:
        connection.request("GET", path,
                           headers={"Host": hostname, "Connection": "close"})
        response = connection.getresponse()
        digest = hashlib.sha256(response.read()).hexdigest()
        return response.status, response.getheader("Location"), digest
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--address", required=True)
    parser.add_argument("--ca-file", required=True)
    parser.add_argument("--lab", required=True)
    parser.add_argument("--routes", required=True)
    parser.add_argument("--denied-source", help="Optional local source IP outside the allowed RustFS client networks")
    args = parser.parse_args()
    lab = json.loads(Path(args.lab).read_text())
    routes = json.loads(Path(args.routes).read_text())
    addresses = {vm["name"]: vm["ip"] for vm in lab["vms"]}
    addresses["firewall"] = lab["firewall"]["lanIp"]
    context = ssl.create_default_context(cafile=args.ca_file)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    for route in routes["tls"]:
        for name in route["names"]:
            hostname = lab["domain"] if name == "@" else name + "." + lab["domain"]
            direct = leaf(addresses[route["vm"]], route["port"], hostname, context)
            proxied = leaf(args.address, 443, hostname, context)
            if direct != proxied:
                raise RuntimeError(f"TLS certificate changed at ingress for {hostname}")
            print(f"PASS: {hostname}: verified TLS, same certificate via central nginx")
    for route in routes["http"]:
        for name in route["names"]:
            hostname = lab["domain"] if name == "@" else name + "." + lab["domain"]
            direct = http_result(addresses[route["vm"]], route["port"], hostname)
            proxied = http_result(args.address, 80, hostname)
            if direct != proxied:
                raise RuntimeError(f"HTTP challenge path or redirect changed for {hostname}")
            print(f"PASS: {hostname}: HTTP challenge path preserved (HTTP {proxied[0]})")
            if route["vm"] == "vault":
                for path in ("/pki/root-ca.crt", "/pki/root-ca.crl", "/v1/pki_int/ca", "/v1/pki_int/crl"):
                    direct = http_result(addresses[route["vm"]], route["port"], hostname, path)
                    proxied = http_result(args.address, 80, hostname, path)
                    if direct != proxied or proxied[0] != 200:
                        raise RuntimeError(f"Public CA/CRL content changed at {path}")
                    print(f"PASS: {hostname}{path}: identical public CA/CRL bytes via central nginx")
    for route in routes.get("tcp", []):
        hostname = route["vm"] + "." + lab["domain"]
        direct = leaf(addresses[route["vm"]], route["port"], hostname, context)
        proxied = leaf(args.address, route["listen"], hostname, context)
        if direct != proxied:
            raise RuntimeError(f"TLS certificate changed on compatibility port {route['listen']}")
        print(f"PASS: {hostname}:{route['listen']}: verified TLS via central nginx")
    assert_handshake_rejected(args.address, "unconfigured-domain." + lab["domain"])
    print("PASS: unknown SNI is rejected before TLS handshake")
    assert_handshake_rejected(args.address, None)
    print("PASS: missing SNI is rejected before TLS handshake")
    if args.denied_source:
        control_route = next(route for route in routes["tls"] if route["vm"] not in ("rustfs", "firewall"))
        control_name = control_route["names"][0]
        control_host = lab["domain"] if control_name == "@" else control_name + "." + lab["domain"]
        leaf(args.address, 443, control_host, context, args.denied_source)
        print(f"PASS: source {args.denied_source} reaches unrestricted {control_host} as a positive control")
        for route in routes["tls"]:
            if route["vm"] in ("rustfs", "firewall"):
                for name in route["names"]:
                    hostname = name + "." + lab["domain"]
                    assert_handshake_rejected(args.address, hostname, args.denied_source)
                    print(f"PASS: {hostname}: disallowed source {args.denied_source} rejected before TLS handshake")


if __name__ == "__main__":
    main()
