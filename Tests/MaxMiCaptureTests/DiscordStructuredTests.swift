import XCTest
import MaxMiCore
@testable import MaxMiCapture

final class DiscordStructuredTests: XCTestCase {
    /// Every frame here is deliberately identical and wrong — Discord's virtualised list collapses
    /// nodes onto one y and contradicts itself on x. A geometry-free parser must not care.
    let bogusFrame = CGRect(x: 0, y: 0, width: 0, height: 0)

    func node(_ role: String, value: String? = nil, title: String? = nil, label: String? = nil,
              identifier: String? = nil, children: [AXNode] = []) -> AXNode {
        AXNode(role: role, value: value, title: title, url: nil, frame: bogusFrame,
               focused: false, children: children, identifier: identifier, label: label)
    }

    func text(_ value: String) -> AXNode { node("AXStaticText", value: value) }

    /// Sidebar chrome plus a "Messages in general" list holding two grouped messages, the second
    /// group containing two consecutive messages under one heading.
    func window(listLabel: String = "Messages in general") -> AXNode {
        node("AXWindow", title: "#general | Acme - Discord", children: [
            node("AXList", label: "Channels", children: [text("random-channel")]),
            node("AXList", label: listLabel, children: [
                node("AXGroup", children: [
                    node("AXHeading", value: "Ada"),
                    text("index rebuilt"),
                ]),
                node("AXGroup", children: [
                    node("AXHeading", value: "Grace"),
                    text("deploy looks green"),
                    text("shipping now"),
                ]),
            ]),
        ])
    }

    func context(_ title: String?) -> ParseContext {
        ParseContext(app: AppInfo(bundleID: ParserRegistry.discordBundleID, name: "Discord",
                                  windowTitle: title))
    }

    func conversation(_ content: CapturedContent?) throws -> Conversation {
        guard case .conversation(let c) = try XCTUnwrap(content) else {
            XCTFail("expected .conversation, got \(String(describing: content))")
            throw NSError(domain: "ExpectedContentShape", code: 1)
        }
        return c
    }

    func testConfigClaimsTheAppAndTheWebHosts() {
        XCTAssertEqual(DiscordParser.config.bundleIDs, [ParserRegistry.discordBundleID])
        XCTAssertEqual(DiscordParser.config.hosts, ["discord.com", "www.discord.com"])
        XCTAssertTrue(DiscordParser.config.preferOverNative)
        let registry = ParserRegistry()
        XCTAssertTrue(registry.structuredParser(for: ParserRegistry.discordBundleID) is DiscordParser)
        XCTAssertTrue(registry.structuredParser(forHost: "discord.com") is DiscordParser)
    }

    func testChannelNameComesFromTheTitle() {
        XCTAssertEqual(DiscordParser.channelName(fromTitle: "#general | Acme - Discord"), "general")
        XCTAssertEqual(DiscordParser.channelName(fromTitle: "Friends - Discord"), "Friends")
        XCTAssertEqual(DiscordParser.channelName(fromTitle: nil), "unknown")
    }

    func testMessageListIsFoundByIdentifierOrLabelContainingMessagesIn() throws {
        XCTAssertEqual(try XCTUnwrap(DiscordParser.messageList(in: window())).label,
                       "Messages in general")
        let byIdentifier = node("AXWindow", children: [
            node("AXList", identifier: "chat-messages Messages in general",
                 children: [node("AXGroup", children: [node("AXHeading", value: "Ada"),
                                                       text("hi")])]),
        ])
        XCTAssertNotNil(DiscordParser.messageList(in: byIdentifier))
        XCTAssertNil(DiscordParser.messageList(in: node("AXWindow",
                                                        children: [node("AXList", label: "Servers")])))
    }

    func testGroupHeadingBecomesTheSenderOfEveryMessageInThatGroup() throws {
        let c = try conversation(DiscordParser().parse(window(),
                                                      context: context("#general | Acme - Discord")))
        XCTAssertEqual(c.channel, "general")
        XCTAssertTrue(c.isGroup)
        XCTAssertEqual(c.messages.map(\.sender), ["Ada", "Grace", "Grace"],
                       "consecutive messages inherit their group's heading — the attribution fix")
        XCTAssertEqual(c.messages.map(\.text),
                       ["index rebuilt", "deploy looks green", "shipping now"])
        XCTAssertEqual(c.messages.map(\.isUser), [false, false, false])
    }

    func testSidebarChannelsAreStructurallyOutOfReach() throws {
        let c = try conversation(DiscordParser().parse(window(),
                                                      context: context("#general | Acme - Discord")))
        XCTAssertFalse(c.messages.contains { $0.text.contains("random-channel") },
                       "the sidebar is a different AXList, so no geometry is needed to exclude it")
    }

    func testKnownUIChromeIsFilteredFromMessageBodies() throws {
        let win = node("AXWindow", title: "#general | Acme - Discord", children: [
            node("AXList", label: "Messages in general", children: [
                node("AXGroup", children: [
                    node("AXHeading", value: "Ada"),
                    text("Add Reaction"),
                    text("index rebuilt"),
                    text("Edited"),
                ]),
            ]),
        ])
        let c = try conversation(DiscordParser().parse(win, context: context("#general | Acme - Discord")))
        XCTAssertEqual(c.messages.map(\.text), ["index rebuilt"])
    }

    func testAGroupWithNoHeadingInheritsThePreviousSender() throws {
        let win = node("AXWindow", title: "#general | Acme - Discord", children: [
            node("AXList", label: "Messages in general", children: [
                node("AXGroup", children: [node("AXHeading", value: "Ada"), text("first")]),
                node("AXGroup", children: [text("second")]),
            ]),
        ])
        let c = try conversation(DiscordParser().parse(win, context: context("#general | Acme - Discord")))
        XCTAssertEqual(c.messages.map(\.sender), ["Ada", "Ada"])
    }

    func testAGroupWithNoHeadingAndNoPrecedingSenderIsAttributedToUnknown() throws {
        let win = node("AXWindow", title: "#general | Acme - Discord", children: [
            node("AXList", label: "Messages in general", children: [
                node("AXGroup", children: [text("orphan")]),
            ]),
        ])
        let c = try conversation(DiscordParser().parse(win, context: context("#general | Acme - Discord")))
        XCTAssertEqual(c.messages.map(\.sender), ["unknown"])
    }

    func testNoMessageListIsNotHandled() throws {
        XCTAssertNil(try DiscordParser().parse(node("AXWindow", children: [node("AXList", label: "Servers")]),
                                           context: context("#general | Acme - Discord")))
    }

    func testResultIsUnaffectedByFrameValuesEntirely() throws {
        // Same tree, every frame replaced with an absurd one. Discord's frames lie; the parser
        // must not read them at all.
        // EVERY field except `frame` is carried over: a rebuild that dropped subrole/heading
        // level/DOM attributes would prove attribute-independence too, and would let a future
        // frame read slip in through a node that kept its own attributes (ruling F25).
        func reframed(_ node: AXNode, _ frame: CGRect) -> AXNode {
            AXNode(role: node.role, value: node.value, title: node.title, url: node.url,
                   frame: frame, focused: node.focused,
                   children: node.children.map { reframed($0, frame) },
                   identifier: node.identifier, label: node.label, subrole: node.subrole,
                   headingLevel: node.headingLevel, selected: node.selected,
                   placeholder: node.placeholder, selectedText: node.selectedText,
                   hidden: node.hidden, domClassList: node.domClassList,
                   domIdentifier: node.domIdentifier)
        }
        let a = try DiscordParser().parse(window(), context: context("#general | Acme - Discord"))
        let b = try DiscordParser().parse(reframed(window(), CGRect(x: -9_999, y: 5, width: 1, height: 1)),
                                      context: context("#general | Acme - Discord"))
        XCTAssertEqual(a, b)
    }

    func testDiscordFixtureMatchesItsGolden() throws {
        assertGolden(try XCTUnwrap(DiscordParser().parse(try fixture("discord-messages"),
                                                        context: context("#general | Acme - Discord"))),
                     matches: "discord-messages-golden")
    }

    func testTheOffsetFixtureProducesTheSameContentAsTheFlushOne() throws {
        // Discord is geometry-free, so the offset recording must produce the SAME typed value —
        // and it is checked against the SAME golden. A second golden file with identical bytes
        // would add no signal (ruling F25), so `discord-offset-messages-golden.json` is not
        // created; the equality below plus the shared golden is the assertion.
        let flush = try XCTUnwrap(DiscordParser().parse(
            try fixture("discord-messages"), context: context("#general | Acme - Discord")))
        let offset = try XCTUnwrap(DiscordParser().parse(
            try fixture("discord-offset-messages"), context: context("#general | Acme - Discord")))
        XCTAssertEqual(flush, offset, "the window origin must not reach the typed value")
        assertGolden(offset, matches: "discord-messages-golden")
    }
}
