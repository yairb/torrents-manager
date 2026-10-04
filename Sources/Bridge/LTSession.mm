#import "LTSession.h"

#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/session_status.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_flags.hpp>
#include <libtorrent/alert.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/bencode.hpp>

#include <pthread/qos.h>

#include <atomic>
#include <chrono>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace lt = libtorrent;

static NSString *const LTSessionErrorDomain = @"LTSessionErrorDomain";

static NSString *hexEncode(std::string const &raw) {
    static char const *const digits = "0123456789abcdef";
    std::string out;
    out.reserve(raw.size() * 2);
    for (unsigned char c : raw) {
        out.push_back(digits[c >> 4]);
        out.push_back(digits[c & 0xF]);
    }
    return [NSString stringWithUTF8String:out.c_str()];
}

static NSString *handleIDForInfoHashes(lt::info_hash_t const &hashes) {
    return hexEncode(hashes.get_best().to_string());
}

static NSError *ltMakeError(NSString *description) {
    return [NSError errorWithDomain:LTSessionErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: description}];
}

static NSError *ltErrorFromErrorCode(lt::error_code const &ec) {
    return ltMakeError([NSString stringWithUTF8String:ec.message().c_str()]);
}

static LTTorrentStatus mapStatus(lt::torrent_status const &st) {
    bool const failed = static_cast<bool>(st.errc);
    if (failed) return LTTorrentStatusFailed;

    bool const paused = static_cast<bool>(st.flags & lt::torrent_flags::paused);

    switch (st.state) {
        case lt::torrent_status::checking_resume_data:
        case lt::torrent_status::checking_files:
            return LTTorrentStatusChecking;
        case lt::torrent_status::downloading_metadata:
            return LTTorrentStatusDownloadingMetadata;
        case lt::torrent_status::downloading:
            return paused ? LTTorrentStatusPaused : LTTorrentStatusDownloading;
        case lt::torrent_status::finished:
            return paused ? LTTorrentStatusPaused : LTTorrentStatusCompleted;
        case lt::torrent_status::seeding:
            return paused ? LTTorrentStatusPaused : LTTorrentStatusSeeding;
        default:
            return paused ? LTTorrentStatusPaused : LTTorrentStatusQueued;
    }
}

@implementation LTFileInfo
- (instancetype)initWithFileIndex:(NSInteger)fileIndex path:(NSString *)path size:(int64_t)size {
    if ((self = [super init])) {
        _fileIndex = fileIndex;
        _path = [path copy];
        _size = size;
    }
    return self;
}
@end

@implementation LTMetadata
- (instancetype)initWithName:(NSString *)name
                    totalSize:(int64_t)totalSize
                        files:(NSArray<LTFileInfo *> *)files
               rawTorrentData:(nullable NSData *)rawTorrentData {
    if ((self = [super init])) {
        _name = [name copy];
        _totalSize = totalSize;
        _files = [files copy];
        _rawTorrentData = [rawTorrentData copy];
    }
    return self;
}
@end

@implementation LTStatusSnapshot
- (instancetype)initWithStatus:(LTTorrentStatus)status
                       progress:(double)progress
                   downloadRate:(int64_t)downloadRate
                     uploadRate:(int64_t)uploadRate
                downloadedBytes:(int64_t)downloadedBytes
                     etaSeconds:(double)etaSeconds {
    if ((self = [super init])) {
        _status = status;
        _progress = progress;
        _downloadRate = downloadRate;
        _uploadRate = uploadRate;
        _downloadedBytes = downloadedBytes;
        _etaSeconds = etaSeconds;
    }
    return self;
}
@end

@interface LTSession () {
    std::unique_ptr<lt::session> _session;
    std::unordered_map<std::string, lt::torrent_handle> _handles;
    std::mutex _handlesMutex;
    std::thread _alertThread;
    std::atomic<bool> _running;
}
@property (nonatomic, copy) NSString *sessionDirectory;
@end

@implementation LTSession

- (instancetype)initWithSessionDirectory:(NSString *)directory {
    if ((self = [super init])) {
        _sessionDirectory = [directory copy];
        _running.store(false);
    }
    return self;
}

- (void)dealloc {
    [self shutdown];
}

#pragma mark - Lifecycle

- (BOOL)start:(NSError **)error {
    if (_session) return YES;

    lt::settings_pack pack;
    pack.set_str(lt::settings_pack::listen_interfaces, "0.0.0.0:6881,[::]:6881");
    pack.set_bool(lt::settings_pack::enable_dht, true);
    // libtorrent defaults this to true, which makes an *upload* limit throttle *downloads*.
    // When it's on, libtorrent estimates the TCP/IP header cost of traffic and drains that
    // estimate from the rate limiters — and the ACKs a fast download generates are outgoing, so
    // they're charged to the upload limiter. One 40-byte ACK per two 1500-byte packets is roughly
    // 1.3% of the download rate, so a 10 KB/s upload cap caps downloads at well under 1 MB/s
    // before a single byte of real upload payload has been sent. Requests and `have` messages
    // then queue behind that and the pipeline starves. Turning it off means the limits apply to
    // BitTorrent traffic only, which is what someone setting "upload limit: 10 KB/s" expects.
    pack.set_bool(lt::settings_pack::rate_limit_ip_overhead, false);
    // Deliberately NOT subscribing to alert_category::piece_progress: it posts
    // block_downloading/block_finished/piece_finished alerts at roughly one per 16 KiB block,
    // i.e. hundreds to thousands per second at any real download rate. `handleAlert:` ignores
    // every one of them, but their sheer volume made wait_for_alert() return instantly on every
    // iteration, turning the alert loop into a busy spin (see -runAlertLoop). file_progress is
    // kept because file_completed_alert is genuinely consumed and is low-volume.
    pack.set_int(lt::settings_pack::alert_mask,
                 lt::alert_category::status
                 | lt::alert_category::error
                 | lt::alert_category::storage
                 | lt::alert_category::file_progress);

    lt::session_params params(std::move(pack));

    try {
        _session = std::make_unique<lt::session>(std::move(params));
    } catch (std::exception const &ex) {
        if (error) *error = ltMakeError([NSString stringWithUTF8String:ex.what()]);
        return NO;
    }

    _running.store(true);
    __weak LTSession *weakSelf = self;
    _alertThread = std::thread([weakSelf] {
        // A raw std::thread inherits whatever QoS the spawning context had, which leaves it
        // liable to being demoted (and throttled harder under App Nap) while the app is in the
        // background. This thread drives every status update the UI sees, so pin it explicitly.
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
        LTSession *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf runAlertLoop];
    });

    return YES;
}

- (void)shutdown {
    if (!_session) return;
    _running.store(false);
    if (_session) {
        _session->post_torrent_updates(); // wake up wait_for_alert
    }
    if (_alertThread.joinable()) {
        _alertThread.join();
    }
    {
        std::lock_guard<std::mutex> lock(_handlesMutex);
        _handles.clear();
    }
    _session.reset();
}

/// Pumps libtorrent's alert queue and asks for a status refresh once a second.
///
/// The status cadence is driven by an explicit clock rather than by the loop's own iteration
/// rate: `wait_for_alert` returns immediately whenever anything is already queued, so posting
/// once per iteration meant post_torrent_updates() fired as fast as alerts arrived — far above
/// the ~1 Hz libtorrent documents, and enough to swamp every layer above this one.
- (void)runAlertLoop {
    constexpr auto kStatusInterval = std::chrono::seconds(1);
    constexpr auto kAlertWait = std::chrono::milliseconds(200);

    // steady_clock::time_point{} is far enough in the past to force a post on the first pass.
    std::chrono::steady_clock::time_point lastStatusPost{};

    while (_running.load()) {
        if (!_session) break;

        auto const now = std::chrono::steady_clock::now();
        if (now - lastStatusPost >= kStatusInterval) {
            _session->post_torrent_updates();
            lastStatusPost = now;
        }

        // Short wait so both the cadence check above and -shutdown's wake-up stay responsive.
        lt::alert *a = _session->wait_for_alert(kAlertWait);
        if (!a) continue;

        std::vector<lt::alert *> alerts;
        _session->pop_alerts(&alerts);
        for (lt::alert *entry : alerts) {
            [self handleAlert:entry];
        }
    }
}

#pragma mark - Alert handling

/// Called on the alert thread. Delegate callbacks are made directly from here rather than
/// hopped onto the main queue: the delegate only forwards into a thread-safe AsyncStream
/// continuation, and funnelling every status update through the main queue was enough to
/// starve the UI of the very thread it needs to draw.
- (void)handleAlert:(lt::alert *)a {
    if (auto *su = lt::alert_cast<lt::state_update_alert>(a)) {
        for (lt::torrent_status const &st : su->status) {
            [self emitStatusUpdate:st];
        }
        return;
    }

    if (auto *md = lt::alert_cast<lt::metadata_received_alert>(a)) {
        NSString *handleID = handleIDForInfoHashes(md->handle.info_hashes());
        LTMetadata *metadata = [self metadataForHandle:md->handle];
        if (metadata) {
            [self.delegate session:self handleID:handleID didReceiveMetadata:metadata];
        }
        return;
    }

    if (auto *fc = lt::alert_cast<lt::file_completed_alert>(a)) {
        NSString *handleID = handleIDForInfoHashes(fc->handle.info_hashes());
        NSInteger fileIndex = static_cast<NSInteger>(static_cast<int>(fc->index));
        [self.delegate session:self handleID:handleID didCompleteFileAtIndex:fileIndex];
        return;
    }

    if (auto *tf = lt::alert_cast<lt::torrent_finished_alert>(a)) {
        NSString *handleID = handleIDForInfoHashes(tf->handle.info_hashes());
        [self.delegate session:self didCompleteTorrentWithHandleID:handleID];
        return;
    }

    if (auto *te = lt::alert_cast<lt::torrent_error_alert>(a)) {
        NSString *handleID = handleIDForInfoHashes(te->handle.info_hashes());
        NSString *message = [NSString stringWithUTF8String:te->error.message().c_str()];
        [self.delegate session:self handleID:handleID didFailWithErrorMessage:message];
        return;
    }
}

- (void)emitStatusUpdate:(lt::torrent_status const &)st {
    NSString *handleID = handleIDForInfoHashes(st.info_hashes);

    double eta = -1.0;
    if (st.download_payload_rate > 0) {
        int64_t remaining = st.total_wanted - st.total_wanted_done;
        if (remaining > 0) {
            eta = static_cast<double>(remaining) / static_cast<double>(st.download_payload_rate);
        } else {
            eta = 0.0;
        }
    }

    LTStatusSnapshot *snapshot = [[LTStatusSnapshot alloc] initWithStatus:mapStatus(st)
                                                                  progress:static_cast<double>(st.progress)
                                                              downloadRate:st.download_payload_rate
                                                                uploadRate:st.upload_payload_rate
                                                           downloadedBytes:st.total_wanted_done
                                                                etaSeconds:eta];

    [self.delegate session:self handleID:handleID didUpdateStatus:snapshot];
}

- (nullable LTMetadata *)metadataForHandle:(lt::torrent_handle const &)handle {
    std::shared_ptr<const lt::torrent_info> ti = handle.torrent_file();
    if (!ti) return nil;
    return [self metadataForTorrentInfo:*ti];
}

- (LTMetadata *)metadataForTorrentInfo:(lt::torrent_info const &)ti {
    lt::file_storage const &fs = ti.files();
    NSMutableArray<LTFileInfo *> *files = [NSMutableArray arrayWithCapacity:static_cast<NSUInteger>(fs.num_files())];
    for (lt::file_index_t idx : fs.file_range()) {
        NSString *path = [NSString stringWithUTF8String:fs.file_path(idx).c_str()];
        int64_t size = fs.file_size(idx);
        NSInteger fileIndex = static_cast<NSInteger>(static_cast<int>(idx));
        [files addObject:[[LTFileInfo alloc] initWithFileIndex:fileIndex path:path size:size]];
    }
    NSString *name = [NSString stringWithUTF8String:ti.name().c_str()];
    NSData *rawTorrentData = [LTSession bencodedTorrentDataForInfo:ti];
    return [[LTMetadata alloc] initWithName:name totalSize:ti.total_size() files:files rawTorrentData:rawTorrentData];
}

+ (nullable NSData *)bencodedTorrentDataForInfo:(lt::torrent_info const &)ti {
    try {
        lt::create_torrent ct(ti);
        lt::entry e = ct.generate();
        std::vector<char> buf;
        lt::bencode(std::back_inserter(buf), e);
        if (buf.empty()) return nil;
        return [NSData dataWithBytes:buf.data() length:buf.size()];
    } catch (std::exception const &) {
        return nil;
    }
}

#pragma mark - Adding torrents

- (nullable NSString *)addTorrentWithMagnetURI:(NSString *)magnetURI
                                destinationPath:(NSString *)destinationPath
                                    startPaused:(BOOL)startPaused
                                          error:(NSError **)error {
    if (!_session) {
        if (error) *error = ltMakeError(@"Session is not started");
        return nil;
    }

    lt::add_torrent_params params;
    lt::error_code ec;
    lt::parse_magnet_uri(std::string(magnetURI.UTF8String), params, ec);
    if (ec) {
        if (error) *error = ltErrorFromErrorCode(ec);
        return nil;
    }

    params.save_path = std::string(destinationPath.UTF8String);
    [self applyStartPaused:startPaused toParams:params];

    lt::error_code addEc;
    lt::torrent_handle handle = _session->add_torrent(std::move(params), addEc);
    if (addEc || !handle.is_valid()) {
        if (error) *error = addEc ? ltErrorFromErrorCode(addEc) : ltMakeError(@"Failed to add torrent");
        return nil;
    }

    return [self storeHandle:handle];
}

- (nullable NSString *)addTorrentWithFileData:(NSData *)fileData
                               destinationPath:(NSString *)destinationPath
                                   startPaused:(BOOL)startPaused
                                         error:(NSError **)error {
    if (!_session) {
        if (error) *error = ltMakeError(@"Session is not started");
        return nil;
    }

    auto buffer = lt::span<char const>(reinterpret_cast<char const *>(fileData.bytes),
                                        static_cast<int>(fileData.length));
    lt::error_code parseEc;
    auto ti = std::make_shared<lt::torrent_info>(buffer, parseEc, lt::from_span);
    if (parseEc) {
        if (error) *error = ltErrorFromErrorCode(parseEc);
        return nil;
    }

    lt::add_torrent_params params;
    params.ti = ti;
    params.save_path = std::string(destinationPath.UTF8String);
    [self applyStartPaused:startPaused toParams:params];

    lt::error_code addEc;
    lt::torrent_handle handle = _session->add_torrent(std::move(params), addEc);
    if (addEc || !handle.is_valid()) {
        if (error) *error = addEc ? ltErrorFromErrorCode(addEc) : ltMakeError(@"Failed to add torrent");
        return nil;
    }

    NSString *handleID = [self storeHandle:handle];

    // Unlike magnet links, a .torrent file already carries full metadata, so libtorrent
    // never posts a metadata_received_alert for it (that alert only fires once metadata is
    // fetched from peers). Emit the equivalent callback ourselves so the UI doesn't stay
    // stuck on its initial "fetching metadata" placeholder forever.
    //
    // This one callback must stay asynchronous, unlike the alert-thread ones. It fires from
    // inside this method, on the caller's thread; delivering it synchronously would let the
    // metadata event be processed before the caller has finished registering the torrent, and
    // the handler drops metadata for an unknown ID — stranding the row on "Fetching metadata…".
    LTMetadata *metadata = [self metadataForTorrentInfo:*ti];
    id<LTSessionDelegate> delegate = self.delegate;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [delegate session:self handleID:handleID didReceiveMetadata:metadata];
    });

    return handleID;
}

- (void)applyStartPaused:(BOOL)startPaused toParams:(lt::add_torrent_params &)params {
    if (startPaused) {
        params.flags |= lt::torrent_flags::paused;
    } else {
        params.flags &= ~lt::torrent_flags::paused;
    }
}

- (NSString *)storeHandle:(lt::torrent_handle const &)handle {
    NSString *handleID = handleIDForInfoHashes(handle.info_hashes());
    std::string key(handleID.UTF8String);
    {
        std::lock_guard<std::mutex> lock(_handlesMutex);
        _handles[key] = handle;
    }
    return handleID;
}

#pragma mark - Handle lookup

- (BOOL)withHandle:(NSString *)handleID error:(NSError **)error body:(void (^)(lt::torrent_handle const &))body {
    std::string key(handleID.UTF8String);
    lt::torrent_handle handle;
    {
        std::lock_guard<std::mutex> lock(_handlesMutex);
        auto it = _handles.find(key);
        if (it == _handles.end()) {
            if (error) *error = ltMakeError(@"Unknown torrent handle");
            return NO;
        }
        handle = it->second;
    }
    if (!handle.is_valid()) {
        if (error) *error = ltMakeError(@"Torrent handle is no longer valid");
        return NO;
    }
    body(handle);
    return YES;
}

#pragma mark - Torrent actions

- (BOOL)pauseHandle:(NSString *)handleID error:(NSError **)error {
    return [self withHandle:handleID error:error body:^(lt::torrent_handle const &handle) {
        handle.unset_flags(lt::torrent_flags::auto_managed);
        handle.pause();
    }];
}

- (BOOL)resumeHandle:(NSString *)handleID error:(NSError **)error {
    return [self withHandle:handleID error:error body:^(lt::torrent_handle const &handle) {
        handle.resume();
    }];
}

- (BOOL)removeHandle:(NSString *)handleID deleteFiles:(BOOL)deleteFiles error:(NSError **)error {
    if (!_session) {
        if (error) *error = ltMakeError(@"Session is not started");
        return NO;
    }
    std::string key(handleID.UTF8String);
    lt::torrent_handle handle;
    {
        std::lock_guard<std::mutex> lock(_handlesMutex);
        auto it = _handles.find(key);
        if (it == _handles.end()) {
            if (error) *error = ltMakeError(@"Unknown torrent handle");
            return NO;
        }
        handle = it->second;
        _handles.erase(it);
    }
    lt::remove_flags_t flags{};
    if (deleteFiles) flags |= lt::session_handle::delete_files;
    _session->remove_torrent(handle, flags);
    return YES;
}

- (BOOL)renameFileForHandle:(NSString *)handleID fileIndex:(NSInteger)fileIndex newName:(NSString *)newName error:(NSError **)error {
    return [self withHandle:handleID error:error body:^(lt::torrent_handle const &handle) {
        handle.rename_file(lt::file_index_t(static_cast<int>(fileIndex)), std::string(newName.UTF8String));
    }];
}

- (BOOL)setFilePriorityForHandle:(NSString *)handleID fileIndex:(NSInteger)fileIndex priority:(NSInteger)priority error:(NSError **)error {
    return [self withHandle:handleID error:error body:^(lt::torrent_handle const &handle) {
        handle.file_priority(lt::file_index_t(static_cast<int>(fileIndex)),
                              lt::download_priority_t(static_cast<std::uint8_t>(priority)));
    }];
}

- (BOOL)moveStorageForHandle:(NSString *)handleID newPath:(NSString *)newPath error:(NSError **)error {
    return [self withHandle:handleID error:error body:^(lt::torrent_handle const &handle) {
        handle.move_storage(std::string(newPath.UTF8String));
    }];
}

#pragma mark - Global settings

- (void)setGlobalDownloadLimit:(int64_t)bytesPerSecond {
    if (!_session) return;
    lt::settings_pack pack;
    pack.set_int(lt::settings_pack::download_rate_limit, static_cast<int>(bytesPerSecond));
    _session->apply_settings(pack);
}

- (void)setGlobalUploadLimit:(int64_t)bytesPerSecond {
    if (!_session) return;
    lt::settings_pack pack;
    pack.set_int(lt::settings_pack::upload_rate_limit, static_cast<int>(bytesPerSecond));
    _session->apply_settings(pack);
}

- (void)setMaxActiveDownloads:(NSInteger)count {
    if (!_session) return;
    lt::settings_pack pack;
    pack.set_int(lt::settings_pack::active_downloads, static_cast<int>(count));
    _session->apply_settings(pack);
}

@end
