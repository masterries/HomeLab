#!/usr/bin/env python3
"""Check source-bound OpenBao tokens through ingress; receive the token only on stdin."""
import argparse
import http.client
import ipaddress
import json
import socket
import ssl
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--address", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--hostname", required=True)
    parser.add_argument("--ca-file", required=True)
    parser.add_argument("--expect-status", type=int, choices=(200, 403), required=True)
    parser.add_argument("--expected-bound-cidr")
    parser.add_argument("--claim-address", help="Test a forged PROXY v1 address from an untrusted direct client")
    parser.add_argument("--health", action="store_true", help="Check the unauthenticated unsealed health endpoint")
    args = parser.parse_args()
    address = str(ipaddress.IPv4Address(args.address))
    claimed = str(ipaddress.IPv4Address(args.claim_address)) if args.claim_address else None
    token = "" if args.health else sys.stdin.readline(8192).strip()
    if not args.health and (not token or "\r" in token or "\n" in token):
        raise ValueError("Expected a token on stdin")
    context = ssl.create_default_context(cafile=args.ca_file)
    context.minimum_version = ssl.TLSVersion.TLSv1_2

    class Connection(http.client.HTTPSConnection):
        def connect(self):
            connection = socket.create_connection((address, args.port), timeout=10)
            try:
                if claimed:
                    header = f"PROXY TCP4 {claimed} {address} 45678 {args.port}\r\n"
                    connection.sendall(header.encode("ascii"))
                self.sock = self._context.wrap_socket(connection, server_hostname=self.host)
            except Exception:
                connection.close()
                raise

    connection = Connection(args.hostname, args.port, context=context, timeout=10)
    try:
        headers = {"Connection": "close"}
        if token:
            headers["X-Vault-Token"] = token
        connection.request("GET", "/v1/sys/health" if args.health else "/v1/auth/token/lookup-self",
                           headers=headers)
        response = connection.getresponse()
        body = response.read()
        if response.status != args.expect_status:
            raise RuntimeError(f"Expected HTTP {args.expect_status}, received {response.status}")
        if args.expected_bound_cidr:
            expected = ipaddress.ip_network(args.expected_bound_cidr)
            actual = [ipaddress.ip_network(value) for value in json.loads(body)["data"]["bound_cidrs"]]
            if actual != [expected]:
                raise RuntimeError("Token source restriction changed")
        label = "unsealed health through trusted proxy" if args.health else ("untrusted PROXY address ignored" if claimed else "source-bound token enforced")
        print(f"PASS: {args.hostname}:{args.port}: {label}, HTTP {response.status}")
    finally:
        connection.close()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Never print a response body, headers, or token data, including on failure.
        print(f"FAIL: OpenBao ingress check ({type(error).__name__})", file=sys.stderr)
        sys.exit(1)
