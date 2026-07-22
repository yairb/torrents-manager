#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Mirrors the subset of libtorrent's torrent_status::state_t that the app cares about.
/// "downloadingMetadata"/"checking" etc. are derived on the Obj-C++ side from the
/// underlying libtorrent state plus paused/error flags, since libtorrent doesn't expose
/// "paused" or "failed" as states of their own.
typedef NS_ENUM(NSInteger, LTTorrentStatus) {
    LTTorrentStatusQueued,
    LTTorrentStatusChecking,
    LTTorrentStatusDownloadingMetadata,
    LTTorrentStatusDownloading,
    LTTorrentStatusSeeding,
    LTTorrentStatusPaused,
    LTTorrentStatusCompleted,
    LTTorrentStatusFailed,
};

@interface LTFileInfo : NSObject
@property (nonatomic, readonly) NSInteger fileIndex;
@property (nonatomic, readonly, copy) NSString *path;
@property (nonatomic, readonly) int64_t size;
@end

@interface LTMetadata : NSObject
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) int64_t totalSize;
@property (nonatomic, readonly, copy) NSArray<LTFileInfo *> *files;
@end

@interface LTStatusSnapshot : NSObject
@property (nonatomic, readonly) LTTorrentStatus status;
@property (nonatomic, readonly) double progress;
@property (nonatomic, readonly) int64_t downloadRate;
@property (nonatomic, readonly) int64_t uploadRate;
@property (nonatomic, readonly) int64_t downloadedBytes;
/// -1 when unknown / not computable yet.
@property (nonatomic, readonly) double etaSeconds;
@end

@class LTSession;

@protocol LTSessionDelegate <NSObject>
- (void)session:(LTSession *)session handleID:(NSString *)handleID didReceiveMetadata:(LTMetadata *)metadata
    NS_SWIFT_NAME(session(_:handleID:didReceiveMetadata:));
- (void)session:(LTSession *)session handleID:(NSString *)handleID didUpdateStatus:(LTStatusSnapshot *)status
    NS_SWIFT_NAME(session(_:handleID:didUpdateStatus:));
- (void)session:(LTSession *)session handleID:(NSString *)handleID didCompleteFileAtIndex:(NSInteger)fileIndex
    NS_SWIFT_NAME(session(_:handleID:didCompleteFileAtIndex:));
- (void)session:(LTSession *)session didCompleteTorrentWithHandleID:(NSString *)handleID
    NS_SWIFT_NAME(session(_:didCompleteTorrentWithHandleID:));
- (void)session:(LTSession *)session handleID:(NSString *)handleID didFailWithErrorMessage:(NSString *)message
    NS_SWIFT_NAME(session(_:handleID:didFailWithErrorMessage:));
@end

/// Thin Objective-C facade over a libtorrent-rasterbar `lt::session`. All libtorrent /
/// C++ types are confined to LTSession.mm — this header must stay pure Objective-C so it
/// can be imported directly into Swift via the bridging header.
@interface LTSession : NSObject

- (instancetype)initWithSessionDirectory:(NSString *)directory NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, weak, nullable) id<LTSessionDelegate> delegate;

- (BOOL)start:(NSError **)error NS_SWIFT_NAME(start());
- (void)shutdown;

/// Both add methods compute and return the torrent's info-hash (hex string) synchronously,
/// before the torrent is actually handed to libtorrent, so callers get a stable handle ID
/// immediately without waiting for an alert.
- (nullable NSString *)addTorrentWithMagnetURI:(NSString *)magnetURI
                                destinationPath:(NSString *)destinationPath
                                    startPaused:(BOOL)startPaused
                                          error:(NSError **)error
    NS_SWIFT_NAME(addTorrent(magnetURI:destinationPath:startPaused:));

- (nullable NSString *)addTorrentWithFileData:(NSData *)fileData
                               destinationPath:(NSString *)destinationPath
                                   startPaused:(BOOL)startPaused
                                         error:(NSError **)error
    NS_SWIFT_NAME(addTorrent(fileData:destinationPath:startPaused:));

- (BOOL)pauseHandle:(NSString *)handleID error:(NSError **)error NS_SWIFT_NAME(pauseHandle(_:));
- (BOOL)resumeHandle:(NSString *)handleID error:(NSError **)error NS_SWIFT_NAME(resumeHandle(_:));
- (BOOL)removeHandle:(NSString *)handleID deleteFiles:(BOOL)deleteFiles error:(NSError **)error
    NS_SWIFT_NAME(removeHandle(_:deleteFiles:));

- (BOOL)renameFileForHandle:(NSString *)handleID fileIndex:(NSInteger)fileIndex newName:(NSString *)newName error:(NSError **)error
    NS_SWIFT_NAME(renameFile(forHandle:fileIndex:newName:));
/// `priority` is libtorrent's raw 0-7 download_priority_t scale (0 = don't download, 4 = default, 7 = top);
/// the caller is responsible for mapping its own priority model onto that scale.
- (BOOL)setFilePriorityForHandle:(NSString *)handleID fileIndex:(NSInteger)fileIndex priority:(NSInteger)priority error:(NSError **)error
    NS_SWIFT_NAME(setFilePriority(forHandle:fileIndex:priority:));
- (BOOL)moveStorageForHandle:(NSString *)handleID newPath:(NSString *)newPath error:(NSError **)error
    NS_SWIFT_NAME(moveStorage(forHandle:newPath:));

- (void)setGlobalDownloadLimit:(int64_t)bytesPerSecond; // 0 = unlimited
- (void)setGlobalUploadLimit:(int64_t)bytesPerSecond; // 0 = unlimited
- (void)setMaxActiveDownloads:(NSInteger)count;

@end

NS_ASSUME_NONNULL_END
