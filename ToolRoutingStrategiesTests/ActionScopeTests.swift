/*
The action policy, tested where it is cheap.

Every tool in this catalog READS. So a request to freeze, transfer,
cancel or close is not a routing problem with a hard answer — it is one
the device cannot serve, and a request that mixes an action with a lookup
goes to the cloud ENTIRE. Serving the half that works would tell the
customer the other half happened.

`LLMRouter.asksForAnAction` decides that from the wording alone, and this
suite is the reason it can be trusted: no model, no device, no MLX,
milliseconds instead of a six-minute judged run.

THE SECOND TEST IS THE IMPORTANT ONE. Every verb in the rule is also a
noun in this domain — "my Amazon dispute", "the rent transfer", "what
fees did I pay" — so an over-eager rule would escalate a dozen requests
the tools serve perfectly well. It is asserted against EVERY lookup in
the shipped dataset rather than a handful chosen by hand, so a new verb
added to the list cannot quietly take a working sample with it.
*/

import Evaluations
import Foundation
import Testing
@testable import ToolRoutingStrategies

@Suite("Action scope")
struct ActionScopeTests {
    /// Asking for something to be done, on its own or alongside a lookup.
    @Test(
        "A request to DO something is caught",
        arguments: [
            // Bare imperatives — the form Stage 2 already got right.
            "Freeze my debit card",
            "cancel my netflix payment",
            "close my savings account",
            "open a new checking account",
            "change my mailing address",
            "Order a replacement debit card",
            "Increase my ATM withdrawal limit",
            "raise my credit limit to 20k",
            "Send 200 euros to my friend in Berlin",
            "Set up a new autopay for my gym membership",
            // Introduced by a verb phrase.
            "I want to dispute a charge from Amazon",
            "please freeze my card",
            // THE ONES THIS RULE EXISTS FOR: an action standing next to a
            // lookup, where Stage 2 answered the lookup and told the
            // customer the action was "outside the scope of the available
            // options" instead of escalating the request whole.
            "Show my recent transactions and cancel the Netflix subscription",
            "Show my balance and transfer $200 to savings",
            "What's my balance and then pay my credit card bill?"
        ]
    )
    func actionsEscalate(_ query: String) {
        #expect(LLMRouter.asksForAnAction(in: query), "\"\(query)\" asks for something to be done")
    }

    /// The other half, and the one that would cost working samples: these
    /// all CONTAIN an action word, as a noun or a past tense, and every
    /// one of them is a request the tools serve.
    @Test(
        "A lookup that merely mentions an action word is left alone",
        arguments: [
            "What's the status of my Amazon dispute, how much was the charge, and what's my credit card balance?",
            "How much did I spend at Amazon, and what's the status of that dispute?",
            "Any update on the charge I disputed?",
            "What fees did I pay and what interest did I earn last month?",
            "When does my rent payment go out?",
            "Do I have enough in checking to cover the rent payment?",
            "List my scheduled and pending payments",
            "Show my recent transactions, pending payments, and scheduled payments",
            "Convert my savings balance to euros",
            "How much is $500 in euros?",
            "Show my card limits and my credit card number"
        ]
    )
    func lookupsAreLeftAlone(_ query: String) {
        #expect(!LLMRouter.asksForAnAction(in: query), "\"\(query)\" is a lookup")
    }

    /// THE REGRESSION GUARD, against the shipped dataset rather than a
    /// list someone remembered to update: if a sample expects tools, the
    /// action rule must not fire on it. Adding a verb to the list without
    /// running this is how a working request starts going to the cloud.
    @Test("No sample the tools can serve is caught by the action rule")
    func noServiceableSampleIsCaught() throws {
        let url = try #require(#bundle.url(forResource: "synthetic_banking_qa", withExtension: "json"))
        let samples = try JSONDecoder().decode(
            [ModelSample<BankingAnswer>].self,
            from: Data(contentsOf: url)
        )
        try #require(samples.count == 60)

        for sample in samples {
            let expected = try #require(sample.expected)
            guard expected.tools != ["none"] else { continue }
            #expect(
                !LLMRouter.asksForAnAction(in: sample.promptDescription),
                """
                "\(sample.promptDescription)" routes to \(expected.tools.joined(separator: ", ")) \
                and would now be escalated to the cloud instead.
                """
            )
        }
    }
}
