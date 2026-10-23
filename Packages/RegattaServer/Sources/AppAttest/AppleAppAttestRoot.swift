import X509

/// Apple's App Attestation Root CA (#158, ADR 0014): the anchor every attestation's `x5c` chains to. Public, valid
/// 2020-03-18 to 2045-03-15. Downloaded with curl from https://www.apple.com/certificateauthority/
/// (`Apple_App_Attestation_Root_CA.pem`, 2026-10-22) and pasted byte for byte: SHA-256 of the DER is
/// `1cb9823ba28ba6ad2d33a006941de2ae4f513ef1d4e831b9f7e0fa7b6242c932`, pinned by `AppleRootTests`. Tests inject
/// their own root through `AppAttestConfig.trustedRoots`.
public enum AppleAppAttestRoot {
    public static let pem = """
        -----BEGIN CERTIFICATE-----
        MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
        JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
        QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
        Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
        biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
        bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
        NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
        Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
        MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
        CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
        53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
        oyFraWVIyd/dganmrduC1bmTBGwD
        -----END CERTIFICATE-----
        """

    /// The parsed root. The PEM is a constant checked by a test, so parsing can't fail at run time.
    public static let certificate: Certificate = try! Certificate(pemEncoded: pem)
}
