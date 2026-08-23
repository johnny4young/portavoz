import XCTest

/// D317 — the management pane and the proposal surface share one durable
/// policy. This one-launch journey proves both directions plus the bounded
/// receipt projection without touching the user's real library.
final class SkillsSettingsUITests: PortavozUITestCase {
    @MainActor
    func testSkillsPaneFailsClosedWhenDurablePolicyCannotLoad() {
        let app = XCUIApplication.portavoz(openSettings: true)
        app.launchArguments.append("-simulate-skill-control-unavailable")
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(
            app.openSettingsCategory(
                "settings-category-skills",
                revealing: "settings-skills-load-error"))
        let retry = app.buttons["settings-skills-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.control(withIdentifier: "settings-skills-pause-all").exists,
            "a missing durable policy must never become implicit authority")
        XCTAssertFalse(
            app.control(withIdentifier: "settings-skill-recap-draft-enabled").exists,
            "a missing durable policy must not expose a partial catalogue")
        retry.click()
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        attachScreenshot(of: app, named: "skills-control-fail-closed")
    }

    @MainActor
    func testFailedSkillControlMutationReloadsWithoutClosingSettings() {
        let app = XCUIApplication.portavoz(openSettings: true)
        app.launchArguments.append(
            "-simulate-skill-control-mutation-unavailable")
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(
            app.openSettingsCategory(
                "settings-category-skills",
                revealing: "settings-skills-pause-all"))
        let pause = app.control(withIdentifier: "settings-skills-pause-all")
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        XCTAssertFalse(Self.isOn(pause))
        pause.click()

        let error = app.control(withIdentifier: "settings-skills-stale-error")
        XCTAssertTrue(
            error.waitForExistence(timeout: 5),
            "an unverified mutation must retain a fail-closed stale state")
        XCTAssertFalse(
            Self.isOn(pause),
            "an unverified response must not look committed before a durable read")
        XCTAssertFalse(pause.isEnabled)

        let reload = app.buttons["settings-skills-stale-retry"]
        XCTAssertTrue(reload.waitForStableFrame(timeout: 5))
        reload.click()

        XCTAssertTrue(
            waitForDisappearance(error),
            "a verified read must clear the stale control state")
        XCTAssertTrue(pause.exists)
        XCTAssertTrue(pause.isEnabled)
        XCTAssertTrue(
            Self.isOn(pause),
            "the verified read must surface the already committed durable state")
        XCTAssertTrue(
            app.control(withIdentifier: "settings-category-skills").exists,
            "recovery must not require closing or reconstructing Settings")
    }

    @MainActor
    func testSkillActivityScopeFailureDoesNotInventRowsOrDisableVerifiedPolicy() {
        let app = XCUIApplication.portavoz(openSettings: true)
        app.launchArguments.append("-simulate-skill-receipt-scope-unavailable")
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(
            app.openSettingsCategory(
                "settings-category-skills",
                revealing: "settings-skills-pause-all"))
        let pause = app.control(withIdentifier: "settings-skills-pause-all")
        let completed = app.control(
            withIdentifier: "settings-skills-receipt-scope-completed")
        scrollToVisible(completed, in: app)
        XCTAssertTrue(completed.waitForExistence(timeout: 5))
        completed.click()

        XCTAssertTrue(
            app.control(withIdentifier: "settings-skills-receipt-scope-error")
                .waitForExistence(timeout: 5),
            "an unverified scope must show no stale rows")
        XCTAssertTrue(pause.exists)
        XCTAssertTrue(
            pause.isEnabled,
            "a receipt-only failure must preserve the last verified policy")
        XCTAssertFalse(
            app.control(withIdentifier: "settings-skills-stale-error").exists,
            "receipt failure must not claim a policy mutation was unverified")
        let retry = app.buttons["settings-skills-receipt-scope-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.click()
        XCTAssertTrue(
            app.control(withIdentifier: "settings-skills-receipt-scope-error")
                .waitForExistence(timeout: 5))
        attachScreenshot(of: app, named: "skills-activity-scope-failure")
    }

    @MainActor
    func testSkillActivityTransitionsHideStaleRowsAndKeepVerifiedControlsUsable() {
        let app = XCUIApplication.portavoz(seedDemo: true)
        app.launchArguments.append(contentsOf: [
            "-seed-skill-waiting",
            "-simulate-skill-receipt-refresh-delay",
            "-simulate-skill-proposal-refresh-delay"
        ])
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        openSeededMeeting(in: app)
        XCTAssertTrue(
            app.control(withIdentifier: "skill-offer-menu")
                .waitForExistence(timeout: 10),
            "the real producer must publish the proposal controls first")
        openSkillsSettings(in: app)

        let pause = app.control(withIdentifier: "settings-skills-pause-all")
        let skill = app.control(
            withIdentifier: "settings-skill-recap-draft-enabled")
        let proposal = proposalDismissalControl(
            "action",
            skillID: "email-recap-draft",
            in: app)
        XCTAssertTrue(proposal.waitForExistence(timeout: 10))
        scrollToVisible(proposal, in: app, deltaY: -40)
        XCTAssertTrue(proposal.waitForStableFrame(timeout: 5))

        let proposalRefresh = app.buttons[
            "settings-skills-proposals-refresh"]
        scrollToVisible(proposalRefresh, in: app, deltaY: 40)
        XCTAssertTrue(proposalRefresh.waitForStableFrame(timeout: 5))
        proposalRefresh.click()
        let proposalRefreshing = app.control(
            withIdentifier: "settings-skills-proposals-refreshing")
        XCTAssertTrue(
            proposalRefreshing.waitForExistence(timeout: 2),
            "explicit refresh must expose its bounded read")
        XCTAssertTrue(
            proposal.exists,
            "refresh may retain only the last verified proposal snapshot")
        XCTAssertFalse(
            proposal.isEnabled,
            "retained proposal actions must stay inert until refresh verifies them")
        XCTAssertTrue(proposalRefresh.waitForStableFrame(timeout: 10))
        XCTAssertTrue(proposal.isEnabled)

        let waiting = app.control(
            withIdentifier: "settings-skills-receipt-scope-waiting")
        scrollToVisible(waiting, in: app, deltaY: -40)
        XCTAssertTrue(waiting.waitForStableFrame(timeout: 5))
        let receipt = app.control(
            withIdentifier: "settings-skill-receipt-recap-draft")
        XCTAssertTrue(receipt.exists, "Recent must begin with verified evidence")
        waiting.click()

        let loading = app.control(
            withIdentifier: "settings-skills-receipt-scope-loading")
        XCTAssertTrue(loading.waitForExistence(timeout: 2))
        XCTAssertFalse(
            receipt.exists,
            "a scope load must hide rows from the prior snapshot immediately")
        for control in [pause, skill, proposal] {
            XCTAssertTrue(control.exists)
            XCTAssertTrue(
                control.isEnabled,
                "receipt loading must not disable independently verified controls")
        }

        XCTAssertTrue(receipt.waitForExistence(timeout: 5))
        scrollToVisible(receipt, in: app, deltaY: -40)
        receipt.click()
        XCTAssertTrue(
            app.control(withIdentifier: "skill-receipt-inspection")
                .waitForExistence(timeout: 5))
        let revoke = app.buttons["skill-receipt-revoke-action"]
        XCTAssertTrue(revoke.waitForStableFrame(timeout: 5))
        revoke.click()
        XCTAssertTrue(
            app.control(withIdentifier: "skill-receipt-inspection-event-2")
                .waitForExistence(timeout: 5))
        app.buttons["skill-receipt-inspection-close"].click()

        XCTAssertTrue(
            loading.waitForExistence(timeout: 2),
            "a verified receipt mutation must hide its stale same-scope row")
        XCTAssertFalse(receipt.exists)
        XCTAssertTrue(pause.isEnabled)
        XCTAssertTrue(skill.isEnabled)

        let empty = app.control(
            withIdentifier: "settings-skills-empty-receipts-waiting")
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        let expectedEmpty = UITestLocale.environmentLocale == "es"
            ? "No hay ejecuciones de skills en espera"
            : "No waiting Skill runs"
        XCTAssertTrue(
            waitForLabel(empty, toContain: expectedEmpty),
            "the verified empty state must name the selected scope")
        attachScreenshot(of: app, named: "skills-activity-transition")
    }

    @MainActor
    func testSkillActivityExpandsOlderRunsOnlyAfterExplicitRequest() {
        let app = XCUIApplication.portavoz(seedDemo: true)
        app.launchArguments.append("-seed-skill-history")
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        openSkillsSettings(in: app)

        let limit = app.control(
            withIdentifier: "settings-skills-receipt-history-limit")
        XCTAssertTrue(limit.waitForExistence(timeout: 5))
        let initialLimit = UITestLocale.environmentLocale == "es"
            ? "Cada vista muestra hasta 20 ejecuciones coincidentes en este Mac."
            : "Each view shows up to 20 matching runs on this Mac."
        XCTAssertTrue(waitForLabel(limit, toContain: initialLimit))

        let receiptRows = app.buttons.matching(
            identifier: "settings-skill-receipt-meeting-package-export")
        XCTAssertEqual(
            receiptRows.count,
            20,
            "the initial query must expose only the default receipt window")

        let showMore = app.buttons[
            "settings-skills-receipt-show-more"]
        scrollToVisible(showMore, in: app, deltaY: -120)
        XCTAssertTrue(showMore.waitForStableFrame(timeout: 5))
        showMore.click()

        XCTAssertTrue(
            waitForCount(receiptRows, toEqual: 25, timeout: 10),
            "one explicit expansion must reveal all 25 bounded receipts")
        XCTAssertFalse(
            showMore.exists,
            "the activity view must not become unbounded pagination")

        let expandedLimit = app.control(
            withIdentifier: "settings-skills-receipt-history-limit")
        scrollToVisible(expandedLimit, in: app, deltaY: -120)
        let maximumLimit = UITestLocale.environmentLocale == "es"
            ? "Cada vista muestra hasta 50 ejecuciones coincidentes en este Mac."
            : "Each view shows up to 50 matching runs on this Mac."
        XCTAssertTrue(waitForLabel(expandedLimit, toContain: maximumLimit))
        attachScreenshot(of: app, named: "skills-activity-expanded-history")
    }

    @MainActor
    func testSkillActivityHidesExpansionWhenExactlyOnePageExists() {
        let app = XCUIApplication.portavoz(seedDemo: true)
        app.launchArguments.append("-seed-skill-exact-page-history")
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        openSkillsSettings(in: app)

        let receiptRows = app.buttons.matching(
            identifier: "settings-skill-receipt-meeting-package-export")
        XCTAssertTrue(
            waitForCount(receiptRows, toEqual: 20, timeout: 10),
            "the exact-page fixture must expose all twenty matching receipts")

        let limit = app.control(
            withIdentifier: "settings-skills-receipt-history-limit")
        XCTAssertTrue(limit.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.buttons["settings-skills-receipt-show-more"].exists,
            "an exact 20-row result must not promise a nonexistent successor")
        attachScreenshot(of: app, named: "skills-activity-exact-page")
    }

    @MainActor
    func testSkillActivityRefreshPreservesTheExpandedCurrentScope() {
        let app = XCUIApplication.portavoz(seedDemo: true)
        app.launchArguments.append(contentsOf: [
            "-seed-skill-history",
            "-simulate-skill-receipt-refresh-delay"
        ])
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        openSkillsSettings(in: app)

        let waiting = app.control(
            withIdentifier: "settings-skills-receipt-scope-waiting")
        scrollToVisible(waiting, in: app, deltaY: -40)
        XCTAssertTrue(waiting.waitForStableFrame(timeout: 5))
        waiting.click()

        let loading = app.control(
            withIdentifier: "settings-skills-receipt-scope-loading")
        XCTAssertTrue(loading.waitForExistence(timeout: 2))
        let receiptRows = app.buttons.matching(
            identifier: "settings-skill-receipt-meeting-package-export")
        XCTAssertTrue(waitForCount(receiptRows, toEqual: 20, timeout: 10))

        let showMore = app.buttons[
            "settings-skills-receipt-show-more"]
        scrollToVisible(showMore, in: app, deltaY: -120)
        XCTAssertTrue(showMore.waitForStableFrame(timeout: 5))
        showMore.click()
        XCTAssertTrue(waitForCount(receiptRows, toEqual: 25, timeout: 10))

        let refresh = app.buttons["settings-skills-receipt-refresh"]
        scrollToVisible(refresh, in: app, deltaY: 120)
        XCTAssertTrue(refresh.waitForStableFrame(timeout: 5))
        refresh.click()

        XCTAssertTrue(
            loading.waitForExistence(timeout: 2),
            "explicit refresh must publish the normal loading state")
        XCTAssertTrue(
            waitForCount(receiptRows, toEqual: 0, timeout: 2),
            "refresh must hide the stale same-scope rows while reading")
        XCTAssertTrue(
            waitForCount(receiptRows, toEqual: 25, timeout: 10),
            "refresh must preserve the expanded bounded window")

        let expandedLimit = app.control(
            withIdentifier: "settings-skills-receipt-history-limit")
        let maximumLimit = UITestLocale.environmentLocale == "es"
            ? "Cada vista muestra hasta 50 ejecuciones coincidentes en este Mac."
            : "Each view shows up to 50 matching runs on this Mac."
        XCTAssertTrue(waitForLabel(expandedLimit, toContain: maximumLimit))
        attachScreenshot(of: app, named: "skills-activity-explicit-refresh")
    }

    @MainActor
    func testSkillActivityFiltersExactSkillAndResetsExpansion() {
        let app = XCUIApplication.portavoz(seedDemo: true)
        app.launchArguments.append(contentsOf: [
            "-seed-skill-history",
            "-simulate-skill-receipt-refresh-delay"
        ])
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        openSkillsSettings(in: app)

        let waiting = app.control(
            withIdentifier: "settings-skills-receipt-scope-waiting")
        scrollToVisible(waiting, in: app, deltaY: -40)
        XCTAssertTrue(waiting.waitForStableFrame(timeout: 5))
        waiting.click()

        let loading = app.control(
            withIdentifier: "settings-skills-receipt-scope-loading")
        XCTAssertTrue(loading.waitForExistence(timeout: 2))
        let receiptRows = app.buttons.matching(
            identifier: "settings-skill-receipt-meeting-package-export")
        XCTAssertTrue(waitForCount(receiptRows, toEqual: 20, timeout: 10))

        let filter = app.control(
            withIdentifier: "settings-skills-receipt-skill-filter")
        scrollToVisible(filter, in: app, deltaY: -80)
        XCTAssertTrue(filter.waitForStableFrame(timeout: 5))
        filter.click()
        let recap = app.menuItems[
            "settings-skills-receipt-skill-recap-draft"]
        XCTAssertTrue(recap.waitForExistence(timeout: 5))
        recap.click()

        XCTAssertTrue(
            loading.waitForExistence(timeout: 2),
            "a filter change must hide rows from the previous query")
        XCTAssertTrue(waitForCount(receiptRows, toEqual: 0, timeout: 2))
        let empty = app.control(
            withIdentifier: "settings-skills-empty-receipts-waiting")
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        let recapTitle = UITestLocale.environmentLocale == "es"
            ? "Borrador de recap"
            : "Recap draft"
        let filteredEmpty = UITestLocale.environmentLocale == "es"
            ? "No hay ejecuciones de \(recapTitle) que coincidan con esta vista de actividad."
            : "No \(recapTitle) runs match this activity view."
        XCTAssertTrue(waitForLabel(empty, toContain: filteredEmpty))
        XCTAssertTrue(waitForLabel(filter, toContain: recapTitle))

        filter.click()
        let package = app.menuItems[
            "settings-skills-receipt-skill-meeting-package-export"]
        XCTAssertTrue(package.waitForExistence(timeout: 5))
        package.click()
        XCTAssertTrue(loading.waitForExistence(timeout: 2))
        XCTAssertTrue(
            waitForCount(receiptRows, toEqual: 20, timeout: 10),
            "the exact package filter must query its own first bounded page")

        let showMore = app.buttons[
            "settings-skills-receipt-show-more"]
        scrollToVisible(showMore, in: app, deltaY: -120)
        XCTAssertTrue(showMore.waitForStableFrame(timeout: 5))
        showMore.click()
        XCTAssertTrue(waitForCount(receiptRows, toEqual: 25, timeout: 10))

        scrollToVisible(filter, in: app, deltaY: 120)
        XCTAssertTrue(filter.waitForStableFrame(timeout: 5))
        filter.click()
        let all = app.menuItems[
            "settings-skills-receipt-skill-all"]
        XCTAssertTrue(all.waitForExistence(timeout: 5))
        all.click()
        XCTAssertTrue(loading.waitForExistence(timeout: 2))
        XCTAssertTrue(
            waitForCount(receiptRows, toEqual: 20, timeout: 10),
            "changing the Skill filter must reset the 50-row expansion")

        let limit = app.control(
            withIdentifier: "settings-skills-receipt-history-limit")
        let initialLimit = UITestLocale.environmentLocale == "es"
            ? "Cada vista muestra hasta 20 ejecuciones coincidentes en este Mac."
            : "Each view shows up to 20 matching runs on this Mac."
        XCTAssertTrue(waitForLabel(limit, toContain: initialLimit))
        XCTAssertTrue(showMore.waitForExistence(timeout: 5))
        attachScreenshot(of: app, named: "skills-activity-skill-filter")
    }

    @MainActor
    func testSkillActivityFiltersByUpdatePeriodAndResetsExpansion() {
        let app = XCUIApplication.portavoz(seedDemo: true)
        app.launchArguments.append(contentsOf: [
            "-seed-skill-history",
            "-seed-skill-recent-history",
            "-simulate-skill-receipt-refresh-delay"
        ])
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        openSkillsSettings(in: app)

        let waiting = app.control(
            withIdentifier: "settings-skills-receipt-scope-waiting")
        scrollToVisible(waiting, in: app, deltaY: -40)
        XCTAssertTrue(waiting.waitForStableFrame(timeout: 5))
        waiting.click()

        let loading = app.control(
            withIdentifier: "settings-skills-receipt-scope-loading")
        XCTAssertTrue(loading.waitForExistence(timeout: 2))
        let receiptRows = app.buttons.matching(
            identifier: "settings-skill-receipt-meeting-package-export")
        XCTAssertTrue(waitForCount(receiptRows, toEqual: 20, timeout: 10))

        let showMore = app.buttons[
            "settings-skills-receipt-show-more"]
        scrollToVisible(showMore, in: app, deltaY: -120)
        XCTAssertTrue(showMore.waitForStableFrame(timeout: 5))
        showMore.click()
        XCTAssertTrue(waitForCount(receiptRows, toEqual: 25, timeout: 10))

        let periodFilter = app.control(
            withIdentifier: "settings-skills-receipt-period-filter")
        scrollToVisible(periodFilter, in: app, deltaY: 120)
        XCTAssertTrue(periodFilter.waitForStableFrame(timeout: 5))
        periodFilter.click()
        let pastDay = app.menuItems[
            "settings-skills-receipt-period-past-day"]
        XCTAssertTrue(pastDay.waitForExistence(timeout: 5))
        pastDay.click()

        XCTAssertTrue(
            loading.waitForExistence(timeout: 2),
            "a period change must hide rows from the previous query")
        XCTAssertTrue(waitForCount(receiptRows, toEqual: 0, timeout: 2))
        XCTAssertTrue(
            waitForCount(receiptRows, toEqual: 5, timeout: 10),
            "the rolling 24-hour query must return only the five recent rows")
        let pastDayTitle = UITestLocale.environmentLocale == "es"
            ? "Últimas 24 horas"
            : "Past 24 hours"
        XCTAssertTrue(waitForLabel(periodFilter, toContain: pastDayTitle))
        XCTAssertFalse(showMore.exists)

        let skillFilter = app.control(
            withIdentifier: "settings-skills-receipt-skill-filter")
        scrollToVisible(skillFilter, in: app, deltaY: 80)
        XCTAssertTrue(skillFilter.waitForStableFrame(timeout: 5))
        skillFilter.click()
        let recap = app.menuItems[
            "settings-skills-receipt-skill-recap-draft"]
        XCTAssertTrue(recap.waitForExistence(timeout: 5))
        recap.click()
        XCTAssertTrue(loading.waitForExistence(timeout: 2))
        let empty = app.control(
            withIdentifier: "settings-skills-empty-receipts-waiting")
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        let recapTitle = UITestLocale.environmentLocale == "es"
            ? "Borrador de recap"
            : "Recap draft"
        let filteredEmpty = UITestLocale.environmentLocale == "es"
            ? "No hay ejecuciones de \(recapTitle) que coincidan con el período seleccionado."
            : "No \(recapTitle) runs match the selected time period."
        XCTAssertTrue(waitForLabel(empty, toContain: filteredEmpty))

        let clearFilters = app.buttons[
            "settings-skills-receipt-clear-filters"]
        scrollToVisible(clearFilters, in: app, deltaY: -80)
        XCTAssertTrue(clearFilters.waitForStableFrame(timeout: 5))
        clearFilters.click()
        XCTAssertTrue(loading.waitForExistence(timeout: 2))
        XCTAssertTrue(
            waitForCount(receiptRows, toEqual: 20, timeout: 10),
            "clearing filters must preserve Waiting and reset to its first page")
        let allSkillsTitle = UITestLocale.environmentLocale == "es"
            ? "Todos los skills"
            : "All skills"
        XCTAssertTrue(waitForLabel(skillFilter, toContain: allSkillsTitle))
        let anytimeTitle = UITestLocale.environmentLocale == "es"
            ? "Cualquier momento"
            : "Any time"
        XCTAssertTrue(waitForLabel(periodFilter, toContain: anytimeTitle))
        XCTAssertFalse(clearFilters.exists)

        scrollToVisible(periodFilter, in: app, deltaY: 80)
        XCTAssertTrue(periodFilter.waitForStableFrame(timeout: 5))
        periodFilter.click()
        XCTAssertTrue(pastDay.waitForExistence(timeout: 5))
        pastDay.click()
        XCTAssertTrue(loading.waitForExistence(timeout: 2))
        XCTAssertTrue(waitForCount(receiptRows, toEqual: 5, timeout: 10))

        scrollToVisible(skillFilter, in: app, deltaY: 80)
        XCTAssertTrue(skillFilter.waitForStableFrame(timeout: 5))
        skillFilter.click()
        let package = app.menuItems[
            "settings-skills-receipt-skill-meeting-package-export"]
        XCTAssertTrue(package.waitForExistence(timeout: 5))
        package.click()
        XCTAssertTrue(loading.waitForExistence(timeout: 2))
        XCTAssertTrue(waitForCount(receiptRows, toEqual: 5, timeout: 10))

        scrollToVisible(periodFilter, in: app, deltaY: 80)
        XCTAssertTrue(periodFilter.waitForStableFrame(timeout: 5))
        periodFilter.click()
        let anytime = app.menuItems[
            "settings-skills-receipt-period-anytime"]
        XCTAssertTrue(anytime.waitForExistence(timeout: 5))
        anytime.click()
        XCTAssertTrue(loading.waitForExistence(timeout: 2))
        XCTAssertTrue(
            waitForCount(receiptRows, toEqual: 20, timeout: 10),
            "changing the period must reset the 50-row expansion")

        let limit = app.control(
            withIdentifier: "settings-skills-receipt-history-limit")
        let initialLimit = UITestLocale.environmentLocale == "es"
            ? "Cada vista muestra hasta 20 ejecuciones coincidentes en este Mac."
            : "Each view shows up to 20 matching runs on this Mac."
        XCTAssertTrue(waitForLabel(limit, toContain: initialLimit))
        XCTAssertTrue(showMore.waitForExistence(timeout: 5))
        attachScreenshot(of: app, named: "skills-activity-period-filter")
    }

    @MainActor
    func testSkillProposalFailureDoesNotInventOffersOrDisableVerifiedPolicy() {
        let app = XCUIApplication.portavoz(openSettings: true)
        app.launchArguments.append("-simulate-skill-proposal-unavailable")
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(
            app.openSettingsCategory(
                "settings-category-skills",
                revealing: "settings-skills-pause-all"))
        let pause = app.control(withIdentifier: "settings-skills-pause-all")
        let error = app.control(
            withIdentifier: "settings-skills-proposals-error")
        scrollToVisible(error, in: app)
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(pause.exists)
        XCTAssertTrue(
            pause.isEnabled,
            "a proposal-only failure must preserve verified execution policy")
        XCTAssertFalse(
            app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier BEGINSWITH 'settings-skill-proposal-'"
            )).firstMatch.exists,
            "an unverified authority must never invent an offer row")
        let retry = app.buttons["settings-skills-proposals-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.click()
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        attachScreenshot(of: app, named: "skills-proposal-fail-closed")
    }

    @MainActor
    func testProposedSkillReviewReturnsToItsMeetingWithoutRunning() {
        let app = XCUIApplication.portavoz(seedDemo: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        openSeededMeeting(in: app)
        XCTAssertTrue(
            app.control(withIdentifier: "skill-offer-menu")
                .waitForExistence(timeout: 10),
            "the original Meeting Detail must publish before central review")
        let insights = app.control(withIdentifier: "library-insights-button")
        XCTAssertTrue(insights.waitForStableFrame(timeout: 5))
        insights.click()
        XCTAssertFalse(
            app.control(withIdentifier: "skill-offer-menu").exists,
            "the journey must leave Meeting Detail before testing the return")
        openSkillsSettings(in: app)

        let review = proposalReviewControl(
            "action",
            skillID: "email-recap-draft",
            in: app)
        scrollToVisible(review, in: app, deltaY: -40)
        XCTAssertTrue(review.waitForStableFrame(timeout: 5))
        review.click()

        let offerMenu = app.control(withIdentifier: "skill-offer-menu")
        XCTAssertTrue(
            offerMenu.waitForStableFrame(timeout: 10),
            "opaque review must close Settings and reopen the exact subject")
        let primaryWindows = app.windows.matching(NSPredicate(
            format: "identifier BEGINSWITH 'main-AppWindow-'"))
        XCTAssertEqual(
            primaryWindows.count,
            1,
            "value-scoped opening must not duplicate the primary window")
        XCTAssertFalse(
            app.control(withIdentifier: "skill-confirm-sheet").exists,
            "navigation alone must never confirm or execute a Skill")
        offerMenu.click()
        XCTAssertTrue(
            app.menuItems["skill-offer-email-recap-draft"]
                .waitForExistence(timeout: 5),
            "the original offer must still require its exact preview")
        app.typeKey(.escape, modifierFlags: [])
        attachScreenshot(of: app, named: "skills-proposal-review-context")
    }

    @MainActor
    func testFailedProposedSkillReviewKeepsTheOfferAndAllowsRetry() {
        let app = XCUIApplication.portavoz(seedDemo: true)
        app.launchArguments.append(
            "-simulate-skill-proposal-review-unavailable")
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        openSeededMeeting(in: app)
        XCTAssertTrue(
            app.control(withIdentifier: "skill-offer-menu")
                .waitForExistence(timeout: 10))
        openSkillsSettings(in: app)

        let review = proposalReviewControl(
            "action",
            skillID: "email-recap-draft",
            in: app)
        let proposalRow = proposalReviewRow(
            skillID: "email-recap-draft",
            in: app)
        scrollToVisible(review, in: app, deltaY: -40)
        XCTAssertTrue(review.waitForStableFrame(timeout: 5))
        review.click()

        let error = proposalReviewControl(
            "error",
            skillID: "email-recap-draft",
            in: app)
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        let retry = proposalReviewControl(
            "retry",
            skillID: "email-recap-draft",
            in: app)
        scrollToVisible(retry, in: app, deltaY: -40)
        XCTAssertTrue(retry.waitForStableFrame(timeout: 5))
        XCTAssertTrue(
            proposalRow.exists,
            "an unverified route must retain the durable proposal")
        XCTAssertFalse(
            review.exists,
            "the inline retry must not duplicate the review action")
        XCTAssertTrue(
            proposalDismissalControl(
                "action",
                skillID: "email-recap-draft",
                in: app).exists,
            "a navigation-only failure must not remove independent dismissal")
        retry.click()
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        attachScreenshot(of: app, named: "skills-proposal-review-retry")
    }

    @MainActor
    func testProposedSkillDismissalRetiresTheDurableOfferEverywhere() {
        let app = XCUIApplication.portavoz(seedDemo: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        openSeededMeeting(in: app)
        XCTAssertTrue(
            app.control(withIdentifier: "skill-offer-menu")
                .waitForExistence(timeout: 10),
            "the real Meeting Detail producer must publish its offers first")
        openSkillsSettings(in: app)

        let dismiss = proposalDismissalControl(
            "action",
            skillID: "email-recap-draft",
            in: app)
        let proposalRow = proposalReviewRow(
            skillID: "email-recap-draft",
            in: app)
        scrollToVisible(dismiss, in: app, deltaY: -40)
        XCTAssertTrue(dismiss.waitForStableFrame(timeout: 5))
        dismiss.click()
        XCTAssertTrue(
            waitForDisappearance(proposalRow),
            "verified dismissal must remove the exact opaque review row")
        XCTAssertFalse(
            proposalDismissalControl(
                "error",
                skillID: "email-recap-draft",
                in: app).exists)

        closeSettings(in: app)
        reloadSeededMeeting(in: app)
        assertEmailOffer(isPresent: false, in: app)
        attachScreenshot(of: app, named: "skills-proposal-dismissed")
    }

    @MainActor
    func testFailedProposedSkillDismissalKeepsTheOfferAndAllowsRetry() {
        let app = XCUIApplication.portavoz(seedDemo: true)
        app.launchArguments.append(
            "-simulate-skill-proposal-dismiss-unavailable")
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        openSeededMeeting(in: app)
        XCTAssertTrue(
            app.control(withIdentifier: "skill-offer-menu")
                .waitForExistence(timeout: 10))
        openSkillsSettings(in: app)

        let dismiss = proposalDismissalControl(
            "action",
            skillID: "email-recap-draft",
            in: app)
        let proposalRow = proposalReviewRow(
            skillID: "email-recap-draft",
            in: app)
        scrollToVisible(dismiss, in: app, deltaY: -40)
        XCTAssertTrue(dismiss.waitForStableFrame(timeout: 5))
        dismiss.click()

        let error = proposalDismissalControl(
            "error",
            skillID: "email-recap-draft",
            in: app)
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        let retry = proposalDismissalControl(
            "retry",
            skillID: "email-recap-draft",
            in: app)
        scrollToVisible(retry, in: app, deltaY: -40)
        XCTAssertTrue(retry.waitForStableFrame(timeout: 5))
        XCTAssertTrue(proposalRow.exists,
            "an unverified mutation must retain the original offer")
        XCTAssertFalse(dismiss.exists,
            "the inline retry must not duplicate the dismissal action")
        retry.click()
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(proposalRow.exists)

        closeSettings(in: app)
        reloadSeededMeeting(in: app)
        assertEmailOffer(isPresent: true, in: app)
        attachScreenshot(of: app, named: "skills-proposal-dismissal-failure")
    }

    @MainActor
    func testWaitingSkillApprovalCanBeRevokedBeforeHandoff() {
        let app = XCUIApplication.portavoz(seedDemo: true)
        app.launchArguments.append("-seed-skill-waiting")
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        openSkillsSettings(in: app)
        let receipt = openWaitingReceipt(in: app)

        let revoke = app.buttons["skill-receipt-revoke-action"]
        XCTAssertTrue(revoke.waitForStableFrame(timeout: 5))
        revoke.click()

        let terminal = app.control(
            withIdentifier: "skill-receipt-inspection-event-2")
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        let expected = UITestLocale.environmentLocale == "es"
            ? "Cancelado antes de la transferencia"
            : "Cancelled before handoff"
        XCTAssertTrue(waitForLabel(terminal, toContain: expected))
        XCTAssertFalse(revoke.exists)
        attachScreenshot(of: app, named: "skills-waiting-approval-revoked")

        app.buttons["skill-receipt-inspection-close"].click()
        XCTAssertTrue(
            app.control(withIdentifier: "settings-skills-empty-receipts-waiting")
                .waitForExistence(timeout: 5),
            "a verified revocation must refresh the selected Waiting scope")
        XCTAssertFalse(receipt.exists)
    }

    @MainActor
    func testFailedWaitingSkillRevocationKeepsTheReceiptAndRetry() {
        let app = XCUIApplication.portavoz(seedDemo: true)
        app.launchArguments.append(contentsOf: [
            "-seed-skill-waiting",
            "-simulate-skill-receipt-revoke-unavailable"
        ])
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        openSkillsSettings(in: app)
        let receipt = openWaitingReceipt(in: app)

        let revoke = app.buttons["skill-receipt-revoke-action"]
        XCTAssertTrue(revoke.waitForStableFrame(timeout: 5))
        revoke.click()
        let error = app.control(withIdentifier: "skill-receipt-revoke-error")
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        let retry = app.buttons["skill-receipt-revoke-retry"]
        XCTAssertTrue(retry.waitForStableFrame(timeout: 5))
        XCTAssertFalse(revoke.exists)
        XCTAssertFalse(
            app.control(withIdentifier: "skill-receipt-inspection-event-2").exists,
            "an unverified mutation must not invent a cancellation event")
        retry.click()
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        attachScreenshot(of: app, named: "skills-waiting-revocation-failure")

        app.buttons["skill-receipt-inspection-close"].click()
        XCTAssertTrue(receipt.waitForExistence(timeout: 5))
    }

    @MainActor
    func testRecoverableFailedSkillReturnsToItsMeetingWithoutRunning() {
        let app = XCUIApplication.portavoz(seedDemo: true)
        app.launchArguments.append("-seed-skill-failed-recoverable")
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        openSkillsSettings(in: app)
        _ = openFailedReceipt(in: app)

        let recovery = app.buttons["skill-receipt-recovery-action"]
        XCTAssertTrue(recovery.waitForStableFrame(timeout: 5))
        XCTAssertGreaterThan(
            app.windows.count,
            1,
            "the recovery journey must begin with Settings above the primary window")
        recovery.click()

        let offerMenu = app.control(withIdentifier: "skill-offer-menu")
        XCTAssertTrue(
            offerMenu.waitForStableFrame(timeout: 10),
            "safe recovery must return to the exact meeting surface")
        XCTAssertTrue(
            waitForWindowCount(1, in: app, timeout: 10),
            "verified recovery navigation must close Settings; \(windowDiagnostics(in: app))")
        let primaryWindows = app.windows.matching(NSPredicate(
            format: "identifier BEGINSWITH 'main-AppWindow-'"))
        XCTAssertEqual(
            primaryWindows.count,
            1,
            "value-scoped recovery must not duplicate the primary window")
        XCTAssertFalse(
            app.control(withIdentifier: "skill-confirm-sheet").exists,
            "recovery navigation must never confirm or run the failed Skill")
        offerMenu.click()
        XCTAssertTrue(
            app.menuItems["skill-offer-recap-draft"]
                .waitForExistence(timeout: 5),
            "the original surface must rebuild a fresh reviewable proposal")
        app.typeKey(.escape, modifierFlags: [])
        attachScreenshot(of: app, named: "skills-failed-recovery-context")
    }

    @MainActor
    func testFailedRecoveryResolutionKeepsTheReceiptAndAllowsRetry() {
        let app = XCUIApplication.portavoz(seedDemo: true)
        app.launchArguments.append(contentsOf: [
            "-seed-skill-failed-recoverable",
            "-simulate-skill-receipt-recovery-unavailable"
        ])
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        openSkillsSettings(in: app)
        let receipt = openFailedReceipt(in: app)

        let recovery = app.buttons["skill-receipt-recovery-action"]
        XCTAssertTrue(recovery.waitForStableFrame(timeout: 5))
        recovery.click()
        let error = app.control(
            withIdentifier: "skill-receipt-recovery-error")
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        let retry = app.buttons["skill-receipt-recovery-retry"]
        XCTAssertTrue(retry.waitForStableFrame(timeout: 5))
        XCTAssertFalse(recovery.exists)
        XCTAssertTrue(receipt.exists)
        XCTAssertTrue(
            app.control(withIdentifier: "skill-receipt-inspection-event-3")
                .exists,
            "an unverified route must retain the original failure evidence")
        XCTAssertTrue(
            app.control(withIdentifier: "settings-category-skills").exists,
            "failed recovery resolution must not leave Settings")
        retry.click()
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        attachScreenshot(of: app, named: "skills-failed-recovery-retry")
    }

    @MainActor
    func testWaitingReceiptIgnoresUnavailablePolicyAndReviewsSourceWithoutRunning() {
        let app = XCUIApplication.portavoz(seedDemo: true)
        app.launchArguments.append(contentsOf: [
            "-seed-skill-waiting",
            "-simulate-skill-receipt-policy-unavailable"
        ])
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        openSkillsSettings(in: app)
        _ = openWaitingReceipt(in: app)

        let review = app.buttons["skill-receipt-context-action"]
        XCTAssertTrue(review.waitForStableFrame(timeout: 5))
        XCTAssertTrue(
            app.buttons["skill-receipt-revoke-action"].exists,
            "audit-only inspection must preserve its independent Waiting action")
        XCTAssertGreaterThan(
            app.windows.count,
            1,
            "source review must begin with Settings above the primary window")
        review.click()

        XCTAssertTrue(
            app.control(withIdentifier: "detail-header-section")
                .waitForStableFrame(timeout: 10),
            "source review must return to the exact meeting detail")
        XCTAssertTrue(
            waitForWindowCount(1, in: app, timeout: 10),
            "verified source review must close Settings; \(windowDiagnostics(in: app))")
        XCTAssertFalse(
            app.control(withIdentifier: "skill-confirm-sheet").exists,
            "source review must never confirm or run the waiting Skill")
        attachScreenshot(of: app, named: "skills-waiting-receipt-source")
    }

    @MainActor
    func testFailedSourceContextResolutionKeepsReceiptAndAllowsRetry() {
        let app = XCUIApplication.portavoz(seedDemo: true)
        app.launchArguments.append(contentsOf: [
            "-seed-skill-waiting",
            "-simulate-skill-receipt-context-unavailable"
        ])
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        openSkillsSettings(in: app)
        let receipt = openWaitingReceipt(in: app)

        let review = app.buttons["skill-receipt-context-action"]
        XCTAssertTrue(review.waitForStableFrame(timeout: 5))
        review.click()
        let error = app.control(withIdentifier: "skill-receipt-context-error")
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        let retry = app.buttons["skill-receipt-context-retry"]
        XCTAssertTrue(retry.waitForStableFrame(timeout: 5))
        XCTAssertTrue(receipt.exists)
        XCTAssertTrue(
            app.control(withIdentifier: "skill-receipt-inspection-event-1")
                .exists,
            "an unverified route must retain the causal confirmation evidence")
        XCTAssertTrue(
            app.buttons["skill-receipt-revoke-action"].exists,
            "source resolution failure must not remove the independent revoke action")
        XCTAssertTrue(
            app.control(withIdentifier: "settings-category-skills").exists,
            "failed source resolution must not leave Settings")
        retry.click()
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        attachScreenshot(of: app, named: "skills-receipt-source-retry")
    }

    @MainActor
    func testSkillReceiptRestoresKeyboardFocusAndPassesAccessibilityAudit() throws {
        let app = XCUIApplication.portavoz(seedDemo: true)
        app.launchArguments.append("-seed-skill-waiting")
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        openSkillsSettings(in: app)
        try auditSkillDescriptions(in: app)

        let receipt = openWaitingReceipt(in: app)
        let inspection = app.control(
            withIdentifier: "skill-receipt-inspection")
        try auditSkillDescriptions(in: app)

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            waitForDisappearance(inspection),
            "Escape must close the modal receipt inspector")
        XCTAssertTrue(
            receipt.waitForExistence(timeout: 5),
            "dismissal must return to the exact receipt row")
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(
            inspection.waitForExistence(timeout: 5),
            "keyboard focus must return to the receipt that opened the sheet")
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testSkillsPaneControlsOffersAndShowsTheConfirmedReceipt() {
        let app = XCUIApplication.portavoz(seedDemo: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        openSkillsSettings(in: app)
        assertInitialCatalogueAndPause(in: app)

        closeSettings(in: app)
        openSeededMeeting(in: app)
        XCTAssertTrue(
            app.control(withIdentifier: "summary-tab-0")
                .waitForExistence(timeout: 10))
        assertOfferMenuStaysAbsent(in: app)

        openSkillsSettings(in: app)
        assertDurableChoicesAndResume(in: app)
        closeSettings(in: app)
        reloadSeededMeeting(in: app)
        confirmRecapOffer(in: app)
        assertRecentReceiptInSettings(in: app)
    }

    @MainActor
    private func assertInitialCatalogueAndPause(in app: XCUIApplication) {
        let pause = app.control(
            withIdentifier: "settings-skills-pause-all")
        let recap = app.control(
            withIdentifier: "settings-skill-recap-draft-enabled")
        let export = app.control(
            withIdentifier: "settings-skill-meeting-package-export-enabled")
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        XCTAssertTrue(recap.waitForExistence(timeout: 5))
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        XCTAssertFalse(Self.isOn(pause))
        XCTAssertTrue(Self.isOn(recap))
        XCTAssertTrue(Self.isOn(export))
        assertDisclosure(
            skillID: "recap-draft",
            expectedText: UITestLocale.environmentLocale == "es"
                ? "Sin transferencia directa por red"
                : "No direct network handoff",
            in: app)
        let reminderDraft = app.control(
            withIdentifier: "settings-skill-reminder-draft-enabled")
        XCTAssertTrue(reminderDraft.waitForExistence(timeout: 5))
        XCTAssertTrue(Self.isOn(reminderDraft))
        let reminderDescription = UITestLocale.environmentLocale == "es"
            ? "Crea un recordatorio local a partir de un compromiso confirmado después de que lo apruebes."
            : "Creates one local reminder from a confirmed commitment after you approve it."
        XCTAssertTrue(
            app.staticTexts[reminderDescription].waitForExistence(timeout: 5),
            "the available Reminder Draft row must not retain planned-feature copy")
        let brief = app.control(
            withIdentifier: "settings-skill-pre-meeting-brief-enabled")
        XCTAssertTrue(brief.waitForExistence(timeout: 5))
        XCTAssertTrue(Self.isOn(brief))
        let email = app.control(
            withIdentifier: "settings-skill-email-recap-draft-enabled")
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        XCTAssertTrue(Self.isOn(email))
        scrollToVisible(email, in: app)
        let emailDescription = UITestLocale.environmentLocale == "es"
            ? "Abre el recap exacto que revisaste en tu app de correo, sin destinatarios. Portavoz nunca lo envía."
            : "Opens the exact reviewed recap in your email app with no recipients. Portavoz never sends it."
        XCTAssertTrue(
            app.staticTexts[emailDescription].waitForExistence(timeout: 5),
            "the external skill must disclose its exact email-app boundary")
        assertDisclosure(
            skillID: "email-recap-draft",
            expectedText: UITestLocale.environmentLocale == "es"
                ? "Puede compartir fuera de Portavoz"
                : "May share outside Portavoz",
            in: app)
        let gist = app.control(
            withIdentifier: "settings-skill-secret-gist-publish-enabled")
        scrollToVisible(gist, in: app)
        XCTAssertTrue(gist.waitForExistence(timeout: 5))
        XCTAssertTrue(Self.isOn(gist))
        let gistDescription = UITestLocale.environmentLocale == "es"
            ? "Publica el documento exacto que revisaste como un Gist secreto de GitHub. Cada ejecución vuelve a pedir confirmación."
            : "Publishes the exact reviewed meeting document as one secret GitHub Gist. Every run asks first."
        XCTAssertTrue(
            app.staticTexts[gistDescription].waitForExistence(timeout: 5),
            "the Gist row must disclose both exact review and per-run consent")
        assertDisclosure(
            skillID: "secret-gist-publish",
            expectedText: UITestLocale.environmentLocale == "es"
                ? "Puede compartir fuera de Portavoz"
                : "May share outside Portavoz",
            in: app)

        // Individual choices survive the independent global pause override.
        export.click()
        XCTAssertTrue(waitForToggle(export, toBeOn: false))
        pause.click()
        XCTAssertTrue(waitForToggle(pause, toBeOn: true))
        XCTAssertTrue(
            app.staticTexts["settings-skills-paused-status"]
                .waitForExistence(timeout: 5))
        attachScreenshot(of: app, named: "skills-control-paused")
    }

    @MainActor
    private func assertDurableChoicesAndResume(in app: XCUIApplication) {
        // The settings snapshot is durable across window reconstruction.
        let durablePause = app.control(
            withIdentifier: "settings-skills-pause-all")
        let durableExport = app.control(
            withIdentifier: "settings-skill-meeting-package-export-enabled")
        XCTAssertTrue(durablePause.waitForExistence(timeout: 5))
        XCTAssertTrue(durableExport.waitForExistence(timeout: 5))
        XCTAssertTrue(Self.isOn(durablePause))
        XCTAssertFalse(Self.isOn(durableExport))
        durablePause.click()
        XCTAssertTrue(waitForToggle(durablePause, toBeOn: false))
    }

    @MainActor
    private func confirmRecapOffer(in app: XCUIApplication) {
        // Resuming restores the recap choice but keeps export disabled.
        let menu = app.control(withIdentifier: "skill-offer-menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        XCTAssertTrue(menu.waitForStableFrame(timeout: 5))
        menu.click()
        let recapOffer = app.menuItems["skill-offer-recap-draft"]
        XCTAssertTrue(recapOffer.waitForExistence(timeout: 5))
        XCTAssertFalse(app.menuItems["skill-offer-package-export"].exists)
        recapOffer.click()

        let submit = app.buttons["skill-confirm-submit"]
        XCTAssertTrue(submit.waitForStableFrame(timeout: 5))
        submit.click()
        XCTAssertTrue(
            app.control(withIdentifier: "skill-receipt-recap-draft")
                .waitForExistence(timeout: 10))
    }

    @MainActor
    private func assertRecentReceiptInSettings(in app: XCUIApplication) {
        openSkillsSettings(in: app)
        assertContentFreeProposals(in: app)
        let receipt = app.control(
            withIdentifier: "settings-skill-receipt-recap-draft")
        XCTAssertTrue(
            receipt.waitForExistence(timeout: 10),
            "the management pane must project the confirmed durable receipt")
        XCTAssertFalse(Self.isOn(app.control(
            withIdentifier: "settings-skill-meeting-package-export-enabled")))
        assertReceiptScopes(in: app, receipt: receipt)
        scrollToVisible(receipt, in: app)
        receipt.click()
        XCTAssertTrue(
            app.control(withIdentifier: "skill-receipt-inspection")
                .waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.control(withIdentifier: "skill-receipt-inspection-privacy")
                .waitForExistence(timeout: 5),
            "the inspector must disclose its content-free boundary")
        var events: [XCUIElement] = []
        for sequence in 1...3 {
            let event = app.control(
                withIdentifier: "skill-receipt-inspection-event-\(sequence)")
            XCTAssertTrue(
                event.waitForExistence(timeout: 5),
                "the confirmed run must expose its complete causal timeline")
            events.append(event)
        }
        let successTitle = UITestLocale.environmentLocale == "es"
            ? "El intento informó éxito"
            : "Attempt reported success"
        XCTAssertTrue(
            waitForLabel(events[2], toContain: successTitle),
            "the terminal event must expose the localized success state")
        attachScreenshot(of: app, named: "skills-control-recent-receipt")
        app.buttons["skill-receipt-inspection-close"].click()
        XCTAssertTrue(receipt.waitForExistence(timeout: 5))
    }

    @MainActor
    private func assertContentFreeProposals(in app: XCUIApplication) {
        let why = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@",
            "settings-skill-proposal-why-email-recap-draft-"
        )).firstMatch
        scrollToVisible(why, in: app)
        XCTAssertTrue(
            why.waitForExistence(timeout: 5),
            "the real Meeting Detail producer must publish its durable offer")
        let expectedWhy = UITestLocale.environmentLocale == "es"
            ? "Hay un resumen de reunión listo para usar."
            : "A meeting summary is ready to use."
        XCTAssertTrue(waitForLabel(why, toContain: expectedWhy))

        let data = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@",
            "settings-skill-proposal-data-secret-gist-publish-"
        )).firstMatch
        scrollToVisible(data, in: app)
        XCTAssertTrue(data.waitForExistence(timeout: 5))
        let expectedData = UITestLocale.environmentLocale == "es"
            ? "transcripción"
            : "transcript"
        XCTAssertTrue(
            waitForLabel(data, toContain: expectedData),
            "the explanation must derive from the Gist's exact input declaration")
        let privacy = app.control(
            withIdentifier: "settings-skills-proposals-privacy")
        XCTAssertTrue(privacy.waitForExistence(timeout: 5))
        for explanation in [why, data, privacy] {
            XCTAssertFalse(explanation.label.contains("Test meeting"))
            XCTAssertFalse(
                explanation.label.contains(
                    "El rollout del modelo queda para el viernes."),
                "the central proposal explanation must not render seeded content")
        }
    }

    @MainActor
    private func assertReceiptScopes(
        in app: XCUIApplication,
        receipt: XCUIElement
    ) {
        let scope = app.control(
            withIdentifier: "settings-skills-receipt-scope")
        let recent = app.control(
            withIdentifier: "settings-skills-receipt-scope-recent")
        let waiting = app.control(
            withIdentifier: "settings-skills-receipt-scope-waiting")
        let attention = app.control(
            withIdentifier: "settings-skills-receipt-scope-needs-attention")
        let completed = app.control(
            withIdentifier: "settings-skills-receipt-scope-completed")
        scrollToVisible(scope, in: app)
        for control in [scope, recent, waiting, attention, completed] {
            XCTAssertTrue(
                control.waitForExistence(timeout: 5),
                "every activity scope must be keyboard and accessibility reachable")
        }

        completed.click()
        XCTAssertTrue(
            receipt.waitForExistence(timeout: 5),
            "the succeeded run belongs to Completed")
        attention.click()
        XCTAssertTrue(
            app.control(withIdentifier:
                "settings-skills-empty-receipts-needs-attention")
                .waitForExistence(timeout: 5),
            "the attention scope must render a verified empty state")
        waiting.click()
        XCTAssertTrue(
            app.control(withIdentifier: "settings-skills-empty-receipts-waiting")
                .waitForExistence(timeout: 5),
            "the waiting scope must render a verified empty state")
        recent.click()
        XCTAssertTrue(
            receipt.waitForExistence(timeout: 5),
            "Recent must restore the newest confirmed receipt")
    }

    @MainActor
    private func openSkillsSettings(in app: XCUIApplication) {
        XCTAssertTrue(
            app.openSettingsWindow(),
            "the production Settings command must open its window")
        XCTAssertTrue(
            app.openSettingsCategory(
                "settings-category-skills",
                revealing: "settings-skills-pause-all"),
            "the Skills category must reveal its durable controls")
    }

    @MainActor
    private func auditSkillDescriptions(in app: XCUIApplication) throws {
        try app.performAccessibilityAudit(
            for: .sufficientElementDescription
        ) { issue in
            guard let identifier = issue.element?.identifier else {
                // XCTest audits every open app window. Unidentified findings
                // cannot be proven to belong to the foreground Skills surface.
                return true
            }
            let belongsToSkills =
                identifier.hasPrefix("settings-skill")
                || identifier.hasPrefix("skill-receipt")
            return !belongsToSkills
        }
    }

    @MainActor
    private func openWaitingReceipt(in app: XCUIApplication) -> XCUIElement {
        let waiting = app.control(
            withIdentifier: "settings-skills-receipt-scope-waiting")
        scrollToVisible(waiting, in: app, deltaY: -40)
        XCTAssertTrue(waiting.waitForStableFrame(timeout: 5))
        waiting.click()
        let receipt = app.control(
            withIdentifier: "settings-skill-receipt-recap-draft")
        scrollToVisible(receipt, in: app, deltaY: -40)
        XCTAssertTrue(receipt.waitForStableFrame(timeout: 5))
        receipt.click()
        XCTAssertTrue(
            app.control(withIdentifier: "skill-receipt-inspection")
                .waitForExistence(timeout: 5))
        return receipt
    }

    @MainActor
    private func openFailedReceipt(in app: XCUIApplication) -> XCUIElement {
        let attention = app.control(
            withIdentifier: "settings-skills-receipt-scope-needs-attention")
        scrollToVisible(attention, in: app, deltaY: -40)
        XCTAssertTrue(attention.waitForStableFrame(timeout: 5))
        attention.click()
        let receipt = app.control(
            withIdentifier: "settings-skill-receipt-recap-draft")
        scrollToVisible(receipt, in: app, deltaY: -40)
        XCTAssertTrue(receipt.waitForStableFrame(timeout: 5))
        receipt.click()
        XCTAssertTrue(
            app.control(withIdentifier: "skill-receipt-inspection")
                .waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.control(withIdentifier: "skill-receipt-inspection-event-3")
                .waitForExistence(timeout: 5),
            "the fixture must expose one confirmed failed attempt")
        return receipt
    }

    @MainActor
    private func closeSettings(in app: XCUIApplication) {
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.prepareForInteraction())
    }

    @MainActor
    private func openSeededMeeting(in app: XCUIApplication) {
        let meeting = seededMeeting(in: app)
        XCTAssertTrue(meeting.waitForStableFrame(timeout: 10))
        meeting.click()
    }

    @MainActor
    private func reloadSeededMeeting(in app: XCUIApplication) {
        let insights = app.control(
            withIdentifier: "library-insights-button")
        XCTAssertTrue(insights.waitForStableFrame(timeout: 5))
        insights.click()
        openSeededMeeting(in: app)
    }

    @MainActor
    private func seededMeeting(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH 'library-meeting-'"))
            .firstMatch
    }

    @MainActor
    private func assertOfferMenuStaysAbsent(in app: XCUIApplication) {
        let unexpected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: app.control(withIdentifier: "skill-offer-menu"))
        unexpected.isInverted = true
        XCTAssertEqual(
            XCTWaiter.wait(for: [unexpected], timeout: 2),
            .completed,
            "global pause must keep every proposal off the meeting surface")
    }

    @MainActor
    private func assertEmailOffer(
        isPresent: Bool,
        in app: XCUIApplication
    ) {
        let menu = app.control(withIdentifier: "skill-offer-menu")
        XCTAssertTrue(menu.waitForStableFrame(timeout: 10))
        menu.click()
        let email = app.menuItems["skill-offer-email-recap-draft"]
        if isPresent {
            XCTAssertTrue(
                email.waitForExistence(timeout: 5),
                "a failed central mutation must not hide the subject offer")
        } else {
            XCTAssertFalse(
                email.waitForExistence(timeout: 1),
                "the durable dismissal must hide the offer after re-observation")
            XCTAssertTrue(
                app.menuItems["skill-offer-recap-draft"]
                    .waitForExistence(timeout: 5),
                "dismissing email must not retire an unrelated recap offer")
        }
        app.typeKey(.escape, modifierFlags: [])
    }

    private func proposalDismissalControl(
        _ component: String,
        skillID: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@",
            "settings-skill-proposal-dismiss-\(component)-\(skillID)-"
        )).firstMatch
    }

    private func proposalReviewControl(
        _ component: String,
        skillID: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@",
            "settings-skill-proposal-review-\(component)-\(skillID)-"
        )).firstMatch
    }

    private func proposalReviewRow(
        skillID: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@",
            "settings-skill-proposal-\(skillID)-"
        )).firstMatch
    }

    private func waitForDisappearance(
        _ element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForWindowCount(
        _ expected: Int,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if app.windows.count == expected { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return app.windows.count == expected
    }

    private func windowDiagnostics(in app: XCUIApplication) -> String {
        app.windows.allElementsBoundByIndex.enumerated().map { index, window in
            "#\(index) id=\(window.identifier) label=\(window.label) "
                + "hittable=\(window.isHittable) frame=\(window.frame)"
        }.joined(separator: "; ")
    }

    @MainActor
    private func waitForToggle(
        _ toggle: XCUIElement,
        toBeOn expected: Bool,
        timeout: TimeInterval = 5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if toggle.exists, Self.isOn(toggle) == expected { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return false
    }

    @MainActor
    private func assertDisclosure(
        skillID: String,
        expectedText: String,
        in app: XCUIApplication
    ) {
        let toggle = app.control(
            withIdentifier: "settings-skill-\(skillID)-enabled")
        scrollToVisible(toggle, in: app)
        let disclosure = app.control(
            withIdentifier: "settings-skill-\(skillID)-boundary")
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForLabel(disclosure, toContain: expectedText),
            "the disclosure must follow the executable capability boundary; "
                + "label=\(disclosure.label) value=\(String(describing: disclosure.value))")
        let approvalText = UITestLocale.environmentLocale == "es"
            ? "Requiere aprobación en cada ejecución"
            : "Approval required every time"
        let confirmation = app.control(
            withIdentifier: "settings-skill-\(skillID)-confirmation")
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForLabel(confirmation, toContain: approvalText),
            "an enabled row must still disclose proposal-scoped approval; "
                + "label=\(confirmation.label) value=\(String(describing: confirmation.value))")
    }

    @MainActor
    private func waitForLabel(
        _ element: XCUIElement,
        toContain expectedText: String,
        timeout: TimeInterval = 5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let value = element.value as? String
            if element.exists,
               element.label.contains(expectedText)
                || value?.contains(expectedText) == true
            {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return false
    }

    @MainActor
    private func waitForCount(
        _ query: XCUIElementQuery,
        toEqual expectedCount: Int,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if query.count == expectedCount { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return false
    }

    @MainActor
    private func scrollToVisible(
        _ element: XCUIElement,
        in app: XCUIApplication,
        deltaY: CGFloat = -5
    ) {
        let window = app.windows.containing(
            .any,
            identifier: "settings-skills-pause-all"
        ).firstMatch
        guard window.exists else { return }
        let form = window.scrollViews.element(boundBy: 1)
        guard form.exists else { return }
        for _ in 0..<16 where !element.isHittable {
            form.scroll(byDeltaX: 0, deltaY: deltaY)
        }
    }

    @MainActor
    private static func isOn(_ toggle: XCUIElement) -> Bool {
        (toggle.value as? Int) == 1 || (toggle.value as? String) == "1"
    }
}
