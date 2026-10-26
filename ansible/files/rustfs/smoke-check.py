#!/usr/bin/env python3
"""Verify TLS, private S3 access and object integrity; never print credentials."""
import argparse
import datetime
import hashlib
import hmac
import http.client
import ipaddress
import os
from pathlib import Path
import socket
import ssl
import urllib.error
import urllib.parse
import urllib.request
import uuid


class ConnectAddressHTTPSConnection(http.client.HTTPSConnection):
    """Override the TCP destination without changing TLS or HTTP host identity."""

    def __init__(self, host, *, connect_address, **kwargs):
        super().__init__(host, **kwargs)

        def create_connection(address, *args, **kwargs):
            return socket.create_connection((connect_address, address[1]), *args, **kwargs)

        # HTTPSConnection keeps self.host for SNI and certificate verification. Only its
        # socket factory receives the explicit transport address; no global DNS override.
        self._create_connection = create_connection


class ConnectAddressHTTPSHandler(urllib.request.HTTPSHandler):
    def __init__(self, connect_address, *, context):
        super().__init__(context=context)
        self.connect_address = str(ipaddress.ip_address(connect_address))

    def https_open(self, req):
        def connection(host, **kwargs):
            return ConnectAddressHTTPSConnection(
                host, connect_address=self.connect_address, **kwargs
            )

        return self.do_open(connection, req, context=self._context)


class S3Check:
    def __init__(self, endpoint, ca_file, access_key, secret_key, connect_address=None):
        self.endpoint = endpoint.rstrip("/")
        parsed = urllib.parse.urlsplit(self.endpoint)
        if parsed.scheme != "https" or parsed.path or parsed.query or parsed.username:
            raise ValueError("Expected an HTTPS endpoint without a path or credentials")
        self.host = parsed.netloc
        self.context = ssl.create_default_context(cafile=ca_file)
        self.context.minimum_version = ssl.TLSVersion.TLSv1_2
        self.access_key = access_key
        self.secret_key = secret_key
        # Avoid local HTTP proxies and redirecting an Authorization header to another host.
        https_handler = (
            ConnectAddressHTTPSHandler(connect_address, context=self.context)
            if connect_address is not None
            else urllib.request.HTTPSHandler(context=self.context)
        )
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            https_handler,
            NoRedirect(),
        )

    def request(self, method, path, data=b"", signed=True):
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        day = stamp[:8]
        digest = hashlib.sha256(data).hexdigest()
        headers = {"Host": self.host}
        if signed:
            headers.update({"x-amz-content-sha256": digest, "x-amz-date": stamp})
            names = "host;x-amz-content-sha256;x-amz-date"
            canonical_headers = (
                f"host:{self.host}\nx-amz-content-sha256:{digest}\nx-amz-date:{stamp}\n"
            )
            canonical = "\n".join((method, path, "", canonical_headers, names, digest))
            scope = f"{day}/us-east-1/s3/aws4_request"
            to_sign = "\n".join(("AWS4-HMAC-SHA256", stamp, scope,
                                  hashlib.sha256(canonical.encode()).hexdigest()))
            key = ("AWS4" + self.secret_key).encode()
            for value in (day, "us-east-1", "s3", "aws4_request"):
                key = hmac.new(key, value.encode(), hashlib.sha256).digest()
            signature = hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest()
            headers["Authorization"] = (
                f"AWS4-HMAC-SHA256 Credential={self.access_key}/{scope}, "
                f"SignedHeaders={names}, Signature={signature}"
            )
        req = urllib.request.Request(self.endpoint + path, headers=headers,
                                     data=data if method in ("PUT", "POST") else None,
                                     method=method)
        try:
            with self.opener.open(req, timeout=30) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            # Server error text is deliberately not printed (it can echo request headers).
            return error.code, error.read()

    def verify(self):
        status, _ = self.request("GET", "/", signed=False)
        if status != 403:
            raise RuntimeError(f"Anonymous ListBuckets was not denied: HTTP {status}")
        bucket = "/lab-rustfs-check-" + uuid.uuid4().hex
        obj = bucket + "/roundtrip.bin"
        payload = os.urandom(65536)
        created = False
        uploaded = False
        try:
            status, _ = self.request("PUT", bucket)
            if status != 200:
                raise RuntimeError(f"CreateBucket failed: HTTP {status}")
            created = True
            status, _ = self.request("PUT", obj, payload)
            if status != 200:
                raise RuntimeError(f"PutObject failed: HTTP {status}")
            uploaded = True
            status, received = self.request("GET", obj)
            if status != 200 or hashlib.sha256(received).digest() != hashlib.sha256(payload).digest():
                raise RuntimeError(f"GetObject integrity check failed: HTTP {status}")
            status, _ = self.request("GET", obj, signed=False)
            if status != 403:
                raise RuntimeError(f"Anonymous GetObject was not denied: HTTP {status}")
        finally:
            failures = []
            if uploaded:
                status, _ = self.request("DELETE", obj)
                if status != 204:
                    failures.append(f"DeleteObject HTTP {status}")
            if created:
                status, _ = self.request("DELETE", bucket)
                if status != 204:
                    failures.append(f"DeleteBucket HTTP {status}")
            if failures:
                raise RuntimeError(f"Test cleanup failed for {bucket}: " + "; ".join(failures))
        print("PASS: verified HTTPS, anonymous access denied, S3 upload/download integrity and cleanup")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", required=True)
    parser.add_argument(
        "--connect-address",
        help="Connect to this IP while retaining the endpoint's TLS name and signed Host header",
    )
    parser.add_argument("--ca-file", required=True)
    parser.add_argument("--access-key-file", required=True)
    parser.add_argument("--secret-key-file", required=True)
    args = parser.parse_args()
    check = S3Check(args.endpoint, args.ca_file,
                    Path(args.access_key_file).read_text().strip(),
                    Path(args.secret_key_file).read_text().strip(),
                    connect_address=args.connect_address)
    check.verify()


if __name__ == "__main__":
    main()
