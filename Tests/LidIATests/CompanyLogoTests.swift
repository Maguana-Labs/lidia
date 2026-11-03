import Foundation
import Testing
@testable import LidIA

@Suite("Company logos")
struct CompanyLogoTests {

    @Test("No request is made unless the user turns logos on")
    func offByDefault() {
        #expect(CompanyLogo.directFaviconURL(for: "acme.com", fetchEnabled: false, localOnly: false) == nil)
        #expect(CompanyLogo.directFaviconURL(for: "acme.com", fetchEnabled: true, localOnly: true) == nil)
        #expect(CompanyLogo.directFaviconURL(for: "acme.com", fetchEnabled: true, localOnly: false)
                == URL(string: "https://acme.com/favicon.ico"))
    }

    @Test("Only plain host names are fetched, never via a proxy")
    func hostValidation() {
        for bad in ["acme.com/evil", "acme.com:8080", "user@acme.com", "1.2.3.4", "acme", ".acme.com",
                    "acme..com", "acme.com?x=1", "www.google.com/s2/favicons?domain=acme.com"] {
            #expect(CompanyLogo.directFaviconURL(for: bad, fetchEnabled: true, localOnly: false) == nil, "\(bad)")
        }
        let url = CompanyLogo.directFaviconURL(for: "Sub.Acme-Corp.co.uk", fetchEnabled: true, localOnly: false)
        #expect(url?.host == "sub.acme-corp.co.uk")
    }

    @Test("Monograms are stable and readable")
    func monogram() {
        let a = CompanyLogo.monogram(name: "Acme Corp", domain: "acme.com")
        #expect(a.initials == "AC")
        #expect(a == CompanyLogo.monogram(name: "Acme Corp", domain: "acme.com"))
        #expect(CompanyLogo.monogram(name: "Harborcloud", domain: "harborcloud.example").initials == "HA")
        #expect(CompanyLogo.monogram(name: "", domain: "x.io").initials == "X")
    }
}
