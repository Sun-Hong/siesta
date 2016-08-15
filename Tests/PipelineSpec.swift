//
//  PipelineSpec.swift
//  Siesta
//
//  Created by Paul on 2016/6/4.
//  Copyright © 2016 Bust Out Solutions. All rights reserved.
//

import Siesta
import Quick
import Nimble
import Nocilla

class PipelineSpec: ResourceSpecBase
    {
    override func resourceSpec(service: () -> Service, _ resource: () -> Resource)
        {
        func appender(word: String) -> ResponseContentTransformer<Any,String>
            {
            return ResponseContentTransformer
                {
                let stringContent = $0.content as? String ?? ""
                guard !stringContent.containsString("error on \(word)") else
                    { return nil }
                return stringContent + word
                }
            }

        func makeRequest(expectSuccess expectSuccess: Bool = true)
            {
            stubRequest(resource, "GET").andReturn(200).withBody("🍕")
            let awaitRequest = expectSuccess ? awaitNewData : awaitFailure
            awaitRequest(resource().load(), alreadyCompleted: false)
            }

        func resourceCacheKey(prefix: String) -> TestCacheKey
            { return TestCacheKey(prefix: prefix, path: "/a/b") }

        beforeEach
            {
            service().configure
                {
                $0.config.pipeline.clear()
                for stage in [.decoding, .parsing, .model, .cleanup] as [PipelineStageKey]
                    {
                    $0.config.pipeline[stage].add(
                        appender(stage.description.prefix(3)))
                    }
                }
            }

        describe("stage order")
            {
            it("determines transformer order")
                {
                makeRequest()
                expect(resource().text) == "decparmodcle"
                }

            it("can reorder transformers already added")
                {
                service().configure
                    { $0.config.pipeline.order = [.rawData, .parsing, .cleanup, .model, .decoding] }
                makeRequest()
                expect(resource().text) == "parclemoddec"
                }

            it("will skip unlisted stages")
                {
                service().configure
                    { $0.config.pipeline.order = [.parsing, .decoding] }
                makeRequest()
                expect(resource().text) == "pardec"
                }

            it("supports custom keys")
                {
                service().configure
                    {
                    $0.config.pipeline.order.insert(.funk, atIndex: 3)
                    $0.config.pipeline.order.insert(.silence, atIndex: 1)
                    $0.config.pipeline[.funk].add(appender("♫"))
                    }
                makeRequest()
                expect(resource().text) == "decpar♫modcle"
                }
            }

        describe("individual stage")
            {
            it("runs transformers in the order added")
                {
                service().configure
                    {
                    for solfegg in ["do", "re", "mi"]
                        { $0.config.pipeline[.decoding].add(appender(solfegg)) }
                    }
                makeRequest()
                expect(resource().text) == "decdoremiparmodcle"
                }

            it("can clear and replace transformers")
                {
                service().configure
                    {
                    $0.config.pipeline[.model].removeTransformers()
                    $0.config.pipeline[.model].add(appender("ti"))
                    }
                makeRequest()
                expect(resource().text) == "decparticle"
                }
            }

        describe("cache")
            {
            func configureCache<C: EntityCache>(cache: C, at stageKey: PipelineStageKey)
                {
                service().configure
                    { $0.config.pipeline[stageKey].cacheUsing(cache) }
                }

            func waitForCacheRead(cache: TestCache)
                { expect(cache.receivedCacheRead).toEventually(beTrue()) }

            func waitForCacheWrite(cache: TestCache)
                { expect(cache.receivedCacheWrite).toEventually(beTrue()) }

            describe("read")
                {
                let cache0 = specVar { TestCache(returning: "cache0", for: resourceCacheKey("cache0")) },
                    cache1 = specVar { TestCache(returning: "cache1", for: resourceCacheKey("cache1")) }

                it("reinflates resource with cached content")
                    {
                    configureCache(cache0(), at: .cleanup)
                    expect(resource().text).toEventually(equal("cache0"))
                    }

                it("inflates empty resource if no cached data")
                    {
                    let emptyCache = TestCache("empty")
                    configureCache(emptyCache, at: .cleanup)
                    resource()
                    waitForCacheRead(emptyCache)
                    expect(resource().text) == ""
                    }

                it("ignores cached data if resource populated before cache read completes")
                    {
                    configureCache(cache0(), at: .cleanup)
                    resource().overrideLocalContent("no race conditions here...except in the specs")
                    waitForCacheRead(cache0())
                    expect(resource().text) == "no race conditions here...except in the specs"
                    }

                it("prevents loadIfNeeded() network access if cached data is fresh")
                    {
                    configureCache(cache0(), at: .cleanup)
                    expect(resource().latestData).toEventuallyNot(beNil())
                    expect(resource().loadIfNeeded()).to(beNil())
                    }

                it("allows loadIfNeeded() network access if cached data is stale")
                    {
                    setResourceTime(1000)
                    configureCache(
                        TestCache(returning: "foo", for: resourceCacheKey("foo")),
                        at: .cleanup)

                    setResourceTime(2000)
                    expect(resource().latestData).toEventuallyNot(beNil())
                    stubRequest(resource, "GET").andReturn(200)
                    awaitNewData(resource().loadIfNeeded()!)
                    }

                it("prefers cache hits from later stages")
                    {
                    configureCache(cache1(), at: .cleanup)
                    configureCache(cache0(), at: .model)
                    expect(resource().text).toEventually(equal("cache1"))
                    }

                it("processes cached content with the following stages’ transformers")
                    {
                    configureCache(cache0(), at: .rawData)
                    expect(resource().text).toEventually(equal("cache0decparmodcle"))
                    }

                it("skips cached content that fails subsequent transformation")
                    {
                    configureCache(cache0(), at: .decoding)
                    configureCache(TestCache(
                        returning: "error on cleanup",
                        for: resourceCacheKey("error on cleanup")),
                        at: .parsing)  // see appender() above
                    expect(resource().text).toEventually(equal("cache0parmodcle"))
                    }
                }

            describe("write")
                {
                func expectCacheWrite(to cache: TestCache, content: String)
                    {
                    waitForCacheWrite(cache)
                    expect(Array(cache.entries.keys)) == [resourceCacheKey(cache.name)]
                    expect(cache.entries.values.first?.typedContent()) == content
                    }

                it("caches new data on success")
                    {
                    let testCache = TestCache("new data")
                    configureCache(testCache, at: .cleanup)
                    makeRequest()
                    expectCacheWrite(to: testCache, content: "decparmodcle")
                    }

                it("writes each stage’s output to that stage’s cache")
                    {
                    let parCache = TestCache("par cache"),
                        modCache = TestCache("mod cache")
                    configureCache(parCache, at: .parsing)
                    configureCache(modCache, at: .model)
                    makeRequest()
                    expectCacheWrite(to: parCache, content: "decpar")
                    expectCacheWrite(to: modCache, content: "decparmod")
                    }

                it("does not cache errors")
                    {
                    configureCache(UnwritableCache(), at: .parsing) // Neither at the failed stage...
                    configureCache(UnwritableCache(), at: .model)   // ...nor subsequent ones

                    service().configureTransformer("**", atStage: .parsing)
                        { (_: String, _) -> NSDate? in nil }

                    makeRequest(expectSuccess: false)
                    }

                it("updates cached data timestamp on 304")
                    {
                    let testCache = TestCache("updated data")
                    configureCache(testCache, at: .cleanup)
                    setResourceTime(1000)
                    makeRequest()

                    setResourceTime(2000)
                    stubRequest(resource, "GET").andReturn(304)
                    awaitNotModified(resource().load())
                    expect(testCache.entries[resourceCacheKey("updated data")]?.timestamp)
                        .toEventually(equal(2000))
                    }

                it("clears cached data on local override")
                    {
                    let testCache = TestCache("local override")
                    configureCache(testCache, at: .cleanup)
                    testCache.entries[resourceCacheKey("local override")] =
                        Entity(content: "should go away", contentType: "text/string")

                    resource().overrideLocalData(
                        Entity(content: "should not be cached", contentType: "text/string"))

                    expect(testCache.entries).toEventually(beEmpty())
                    }
                }

            func exerciseCache()
                {
                makeRequest()
                resource().overrideLocalData(
                    Entity(content: "should not be cached", contentType: "text/string"))
                }

            it("can specify a custom workQueue")
                {
                // MainThreadCache will blow up if any cache methods touched off main thread
                let cache = MainThreadCache()
                configureCache(cache, at: .model)

                expect(resource().text).toEventually(equal("bicycle"))
                exerciseCache()

                expect(cache.calls).toEventually(equal(["readEntity", "writeEntity", "removeEntity"]))
                }

            it("can opt out by returning a nil key")
                {
                configureCache(KeylessCache(), at: .model)
                exerciseCache()
                }
            }

        it("can clear previously configured transformers")
            {
            service().configure
                { $0.config.pipeline.clear() }
            makeRequest()
            expect(resource().latestData?.content is NSData) == true
            }
        }
    }


private extension PipelineStageKey
    {
    static let
        funk    = PipelineStageKey(description: "funk"),
        silence = PipelineStageKey(description: "silence")
    }

private class TestCache: EntityCache
    {
    var name: String
    var receivedCacheRead = false, receivedCacheWrite = false
    var entries: [TestCacheKey:Entity] = [:]

    init(_ name: String)
        { self.name = name }

    init(returning content: String, for key: TestCacheKey)
        {
        name = content
        entries[key] = Entity(content: content, contentType: "text/string")
        }

    func key(for resource: Resource) -> TestCacheKey?
        { return TestCacheKey(prefix: name, path: resource.url.path) }

    func readEntity(forKey key: TestCacheKey) -> Entity?
        {
        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                Int64(0.05 * Double(NSEC_PER_SEC))),
            dispatch_get_main_queue())
            { self.receivedCacheRead = true }

        return entries[key]
        }

    func writeEntity(entity: Entity, forKey key: TestCacheKey)
        {
        dispatch_async(dispatch_get_main_queue())
            {
            self.entries[key] = entity
            self.receivedCacheWrite = true
            }
        }

    func removeEntity(forKey key: TestCacheKey)
        { entries.removeValueForKey(key) }
    }

private struct TestCacheKey
    {
    let string: String

    // Including a cache-specific prefix in the key ensure that pipeline correctly
    // associates a cache with the keys it generated.

    init(prefix: String, path: String?)
        { string = "\(prefix)•\(path)" }
    }

extension TestCacheKey: Hashable
    {
    var hashValue: Int
        { return string.hashValue }
    }

private func ==(lhs: TestCacheKey, rhs: TestCacheKey) -> Bool
    {
    return lhs.string == rhs.string
    }

private extension String
    {
    func prefix(n: Int) -> String
        {
        return self[startIndex ..< startIndex.advancedBy(n)]
        }
    }

private class MainThreadCache: EntityCache
    {
    var calls: [String] = []

    func key(for resource: Resource) -> String?
        { return "bi" }

    func readEntity(forKey key: String) -> Entity?
        {
        recordCall("readEntity")
        return Entity(content: "\(key)cy", contentType: "text/bogus")
        }

    func writeEntity(entity: Entity, forKey key: String)
        { recordCall("writeEntity") }

    func removeEntity(forKey key: String)
        { recordCall("removeEntity") }

    var workQueue: dispatch_queue_t
        { return dispatch_get_main_queue() }

    private func recordCall(name: String)
        {
        if !NSThread.isMainThread()
            { fatalError("MainThreadCache method not called on main queue") }
        calls.append(name)
        }
    }

private class KeylessCache: EntityCache
    {
    func key(for resource: Resource) -> String?
        { return nil }

    func readEntity(forKey key: String) -> Entity?
        { fatalError("should not be called") }

    func writeEntity(entity: Entity, forKey key: String)
        { fatalError("should not be called") }

    func removeEntity(forKey key: String)
        { fatalError("should not be called") }

    var workQueue: dispatch_queue_t
        { fatalError("should not be called") }
    }

private struct UnwritableCache: EntityCache
    {
    func key(for resource: Resource) -> NSURL?
        { return resource.url }

    func readEntity(forKey key: NSURL) -> Entity?
        { return nil }

    func writeEntity(entity: Entity, forKey key: NSURL)
        { fatalError("cache should never be written to") }

    func removeEntity(forKey key: NSURL)
        { fatalError("cache should never be written to") }
    }