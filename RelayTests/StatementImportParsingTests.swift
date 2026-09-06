//
//  StatementImportParsingTests.swift
//  RelayTests
//
//  The bank-statement CSV pipeline against a real German export (C24), whose
//  amount column is "-269,83 €" and whose quoted memos are full of commas.
//  Every one of those rows used to be dropped silently: the review screen
//  came up empty and nothing said why.
//

import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Relay

struct StatementImportParsingTests {
    // MARK: - Amounts

    @Test(arguments: [
        ("-269,83 €", -269.83),
        ("1742,84 €", 1742.84),
        ("-0,50 €", -0.50),
        ("1.742,84 €", 1742.84),
        ("1.742,84 EUR", 1742.84),
        ("$1,234.56", 1234.56),
        ("£1,234.56", 1234.56),
        ("-269,83\u{00A0}€", -269.83),
        ("1\u{202F}234,56 €", 1234.56),
        ("+19,58", 19.58),
        ("\u{2212}19,58", -19.58),
        ("269,83-", -269.83),
        ("(269,83)", -269.83),
        ("15,000,000.00", 15_000_000.00),
        ("15.000.000,00", 15_000_000.00),
        ("100", 100),
        ("-100", -100),
    ])
    func parsesDecoratedAmounts(input: String, expected: Double) throws {
        #expect(try AmountParser.parse(input) == expected)
    }

    @Test(arguments: ["", "   ", "€", "abc", "-", "1,5,5"])
    func rejectsValuesWithNoUsableNumber(input: String) {
        #expect(throws: (any Error).self) { try AmountParser.parse(input) }
    }

    // MARK: - Delimiter sniffing

    /// The header has 13 commas; every data row has extra ones inside quoted
    /// fields, so counting raw characters made "," look inconsistent.
    @Test
    func sniffsDelimiterIgnoringCommasInsideQuotes() throws {
        let table = try CSVStatementParser.parse(Data(Self.c24Sample.utf8))
        #expect(table.header == [
            "Transaktionstyp", "Buchungsdatum", "Karteneinsatz", "Betrag", "Zahlungsempfänger",
            "IBAN", "BIC", "Verwendungszweck", "Beschreibung", "Kontonummer", "Kontoname",
            "Kategorie", "Unterkategorie", "Bargeldabhebung",
        ])
        #expect(table.rows.count == 4)
    }

    /// Commas inside the quoted amount must not outvote the real delimiter.
    @Test
    func sniffsSemicolonDelimiterDespiteCommasInAmounts() throws {
        let csv = """
        Datum;Empfänger;Betrag
        07.09.2026;Rewe, Filiale 12;"-19,58 €"
        06.09.2026;Lidl;"-14,80 €"
        """
        let table = try CSVStatementParser.parse(Data(csv.utf8))
        #expect(table.header == ["Datum", "Empfänger", "Betrag"])
        #expect(table.rows[0] == ["07.09.2026", "Rewe, Filiale 12", "-19,58 €"])
    }

    // MARK: - Dates

    @Test
    func detectsGermanDateFormat() {
        let result = DateFormatDetector.detect(samples: ["07.09.2026", "06.09.2026", "31.08.2026"])
        #expect(result.detectedFormat == "dd.MM.yyyy")
    }

    /// C24's "Karteneinsatz" column pairs the date with the time it was posted.
    @Test
    func detectsDateFormatWhenColumnCarriesATime() {
        let result = DateFormatDetector.detect(samples: ["07.09.2026 17:48", "06.09.2026 16:59"])
        #expect(result.detectedFormat == "dd.MM.yyyy")
        #expect(DateFormatDetector.parse("07.09.2026 17:48", format: "dd.MM.yyyy") != nil)
    }

    @Test
    func stillRejectsAStringThatIsNotADate() {
        #expect(DateFormatDetector.parse("Das Futterhaus", format: "dd.MM.yyyy") == nil)
        #expect(DateFormatDetector.parse("07.09.2026 nonsense trailing", format: "dd.MM.yyyy") != nil)
        #expect(DateFormatDetector.parse("nonsense 07.09.2026", format: "dd.MM.yyyy") == nil)
    }

    // MARK: - End to end

    /// With the mapping cached, `resolveRows` asks nothing and must hand back
    /// every row — the bug behind this file was it handing back none.
    @Test
    func resolvesEveryRowOfTheC24Export() async throws {
        let file = SharedStatementFile(
            filename: "Transaktionen.csv",
            data: Data(Self.c24Sample.utf8),
            type: .commaSeparatedText
        )
        var config = FileImportConfig()
        config.csvMappings[FileImportConfig.csvKey(for: Self.c24Header)] = .init(
            dateColumn: 1, payeeColumn: 4, memoColumn: 8, amountColumn: 3, dateFormat: "dd.MM.yyyy"
        )

        let rows = try await StatementFileResolver.resolveRows(
            file: file,
            config: &config,
            askDateColumn: { _, _ in Issue.record("should not ask"); throw CancellationError() },
            askPayeeColumn: { _, _ in Issue.record("should not ask"); throw CancellationError() },
            askMemoColumn: { _, _ in Issue.record("should not ask"); throw CancellationError() },
            askAmountColumn: { _, _ in Issue.record("should not ask"); throw CancellationError() },
            askDateFormat: { _, _ in Issue.record("should not ask"); throw CancellationError() }
        )

        #expect(rows.count == 4)
        #expect(rows.map(\.amount) == [-269.83, -19.58, -0.50, 1742.84])
        #expect(rows.map(\.payeeName) == ["Das Futterhaus", "Rewe", "Haustier", "SO Tier GmbH"])

        let imported = FileImportRowBuilder.build(from: rows)
        #expect(imported.count == 4)
        #expect(Set(imported.map(\.id)).count == 4)
    }

    // MARK: - Review order

    /// The builder's internal sort is by "{milliunits}:{date}" as a string,
    /// which ordered the review list by amount rather than by date.
    @Test
    func reviewRowsComeBackNewestFirst() {
        let rows = [
            Self.statementRow("2026-08-31", "Apple", -9.99),
            Self.statementRow("2026-09-07", "Das Futterhaus", -269.83),
            Self.statementRow("2026-09-03", "Hannah Hien", -100.00),
            Self.statementRow("2026-09-05", "Thalia", -12.99),
        ]
        let built = FileImportRowBuilder.build(from: rows)
        #expect(built.map(\.payeeName) == ["Das Futterhaus", "Thalia", "Hannah Hien", "Apple"])
    }

    /// Ids are the YNAB import_id and the dedup key; reordering must not move them.
    @Test
    func reorderingDoesNotChangeTheIdsOrTheirOccurrenceNumbers() {
        let rows = [
            Self.statementRow("2026-09-05", "Thalia", -12.99),
            Self.statementRow("2026-09-05", "TK Maxx", -12.99),
            Self.statementRow("2026-09-07", "Rewe", -19.58),
        ]
        let built = FileImportRowBuilder.build(from: rows)
        #expect(built.map(\.id) == ["-19580:2026-09-07:1", "-12990:2026-09-05:1", "-12990:2026-09-05:2"])
    }

    /// Same-day order can't ride on whether the preceding sort was stable.
    @Test
    func sameDayRowsAreOrderedDeterministically() {
        let rows = [
            Self.statementRow("2026-09-05", "Thalia", -12.99),
            Self.statementRow("2026-09-05", "Rewe", -4.64),
        ]
        let forwards = FileImportRowBuilder.build(from: rows).map(\.id)
        let backwards = FileImportRowBuilder.build(from: rows.reversed()).map(\.id)
        #expect(forwards == backwards)
    }

    private static func statementRow(_ day: String, _ payee: String, _ amount: Double) -> ImportedStatementRow {
        ImportedStatementRow(
            date: DateFormatter.yyyyMMdd.date(from: day)!,
            payeeName: payee,
            memo: nil,
            amount: amount
        )
    }

    /// A BOM must not ride along into the header key and the column picker.
    @Test
    func stripsAByteOrderMark() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("Datum,Betrag\n07.09.2026,\"-1,00 €\"".utf8))
        let table = try CSVStatementParser.parse(data)
        #expect(table.header.first == "Datum")
    }

    // MARK: - Fixture

    private static let c24Header = [
        "Transaktionstyp", "Buchungsdatum", "Karteneinsatz", "Betrag", "Zahlungsempfänger",
        "IBAN", "BIC", "Verwendungszweck", "Beschreibung", "Kontonummer", "Kontoname",
        "Kategorie", "Unterkategorie", "Bargeldabhebung",
    ]

    /// Four rows from a real C24 export, unedited. The data rows carry 13
    /// fields against a 14-column header — the last column is never emitted.
    private static let c24Sample = """
    Transaktionstyp,Buchungsdatum,Karteneinsatz,Betrag,Zahlungsempfänger,IBAN,BIC,Verwendungszweck,Beschreibung,Kontonummer,Kontoname,Kategorie,Unterkategorie,Bargeldabhebung
    Abbuchung,07.09.2026,07.09.2026 17:48,"-269,83 €",Das Futterhaus,,,,Das Futterhaus FH 2961,2679062001,C24 Smartkonto,Haustiere,Sonstiges Haustiere
    Abbuchung,07.09.2026,07.09.2026 08:06,"-19,58 €",Rewe,,,,REWE Florian Kunke,2679062001,C24 Smartkonto,Lebensmittel,Supermarkt
    Sparen,06.09.2026,,"-0,50 €",Haustier,,,"Aufrundung aus Kartenzahlung vom 05.09.2026 / -9,50 EUR",,2679062001,C24 Smartkonto,Geldanlage,Sonstiges Sparen
    SEPA-Überweisung,26.08.2026,,"1742,84 €",SO Tier GmbH,DE65100900003040304010,BEVODEBBXXX,Lohn / Gehalt 08/2026,,2679062001,C24 Smartkonto,Einkommen,Lohn/ Gehalt
    """
}

private extension DateFormatDetector.Result {
    var detectedFormat: String? {
        if case .detected(let format) = self { return format }
        return nil
    }
}
