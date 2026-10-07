//
//  VisionOffload.m
//  MinisApp
//
//  Native offload handler for `apple-vision`.
//  Subcommands: ocr, barcode, classify, detect, faces, analyze, similarity, overlap,
//               crop, diff, measure
//

#import <Foundation/Foundation.h>
#import <Vision/Vision.h>
#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import "NativeOffloadUtils.h"
#include "kernel/native_offload.h"
#include <unistd.h>

static NSString *const TOOL_NAME = @"apple-vision";

static NSString *const HELP_TEXT =
    @"apple-vision - Image analysis using the Vision framework\n"
     "\n"
     "USAGE:\n"
     "  apple-vision <command> <image-path> [options]\n"
     "\n"
     "COMMANDS:\n"
     "  ocr        Recognize text in image\n"
     "  barcode    Detect barcodes and QR codes\n"
     "  classify   Classify image contents\n"
     "  detect     Detect rectangles/objects\n"
     "  faces      Detect faces\n"
     "  analyze    Combined analysis (ocr + classify + barcode)\n"
     "  similarity Compare two or more images for similarity\n"
     "  overlap    Detect overlapping regions between consecutive image pairs\n"
     "  crop       Crop a region and save it as PNG\n"
     "  diff       Pixel-level difference between two images\n"
     "  measure    Measure distance between two points (UI alignment)\n"
     "\n"
     "CROP / DIFF / MEASURE:\n"
     "  crop <image> --bbox x,y,w,h [--output out.png] [--scale F]\n"
     "    Crop the region (pixels, top-left origin) and save as lossless PNG.\n"
     "    --bbox is REQUIRED and is clamped to image bounds. --scale upscales the\n"
     "    crop (e.g. --scale 2) for closer inspection, capped at 4096px.\n"
     "    Default output is <name>.crop.png next to the input.\n"
     "  diff --baseline a.png --current b.png [--threshold F] [--output diff.png]\n"
     "    (or: diff a.png b.png). Returns mean pixel distance (0-1), fraction of\n"
     "    changed pixels, and the union bounding box of changed areas.\n"
     "    --threshold is per-pixel change sensitivity 0.0-1.0 (default 0.05).\n"
     "    If sizes differ, current is scaled to baseline and \"resized\" is set.\n"
     "    --output writes a heatmap PNG (red = changed).\n"
     "  measure <image> --from x,y --to x,y [--scale F]\n"
     "    Returns dx/dy/Euclidean distance in pixels between two points\n"
     "    (top-left origin), plus angle. --scale is the device pixel ratio\n"
     "    (default 1) used to also report the distance in CSS points.\n"
     "\n"
     "OPTIONS:\n"
     "  --help, -h          Show this help message\n"
     "  --compact           Minimize JSON output\n"
     "  -q, --quiet         Output only data field\n"
     "  --lang <codes>      OCR languages (comma-separated, e.g. zh-Hans,en)\n"
     "  --level <level>     OCR level: fast or accurate (default: accurate)\n"
     "  --limit <N>         Max results for classify/detect\n"
     "  --threshold <F>     Pixel match threshold 0.0-1.0 (default: 0.9 for both similarity and overlap)\n"
     "  --skip-top <px>     Rows to skip from top (status bar/nav bar) for overlap detection\n"
     "  --skip-bottom <px>  Rows to skip from bottom (tab bar/toolbar) for overlap detection\n"
     "  --bbox <x,y,w,h>    Crop region in pixels, top-left origin (crop)\n"
     "  --output <path>     Output PNG path (crop/diff)\n"
     "  --scale <F>         Upscale factor for crop (default 1); device pixel ratio for measure (default 1)\n"
     "  --baseline <path>   Reference image for diff (or first positional arg)\n"
     "  --current <path>    New image for diff (or second positional arg)\n"
     "  --from <x,y>        Start point in pixels for measure\n"
     "  --to <x,y>          End point in pixels for measure\n"
     "\n"
     "NOTES:\n"
     "  <image-path> is automatically translated from iSH guest path to host path.\n"
     "  Supports images in /var/minis/attachments/ and other accessible paths.\n"
     "\n"
     "EXAMPLES:\n"
     "  apple-vision ocr /var/minis/attachments/photo.jpg\n"
     "  apple-vision ocr /var/minis/attachments/doc.png --lang zh-Hans,en --level fast\n"
     "  apple-vision barcode /var/minis/attachments/qr.png --compact -q\n"
     "  apple-vision classify /var/minis/attachments/photo.jpg --limit 5\n"
     "  apple-vision analyze /var/minis/attachments/photo.jpg\n"
     "  apple-vision similarity img1.png img2.png img3.png\n"
     "  apple-vision similarity img1.png img2.png --threshold 0.8\n"
     "  apple-vision overlap top.png bottom.png\n"
     "  apple-vision overlap s1.png s2.png s3.png\n"
     "  apple-vision crop page.png --bbox 0,0,100,200 --output button.png\n"
     "  apple-vision crop page.png --bbox 390,844,200,120 --scale 2\n"
     "  apple-vision diff --baseline target.png --current render.png --threshold 0.05\n"
     "  apple-vision diff old.png new.png --output heatmap.png\n"
     "  apple-vision measure page.png --from 100,200 --to 120,200 --scale 3\n";

// ── Image loading ──

static CGImageRef load_image(NSString *path, NSInteger *outWidth, NSInteger *outHeight) {
    UIImage *img = [UIImage imageWithContentsOfFile:path];
    if (!img) return NULL;
    if (outWidth) *outWidth = (NSInteger)img.size.width;
    if (outHeight) *outHeight = (NSInteger)img.size.height;
    return img.CGImage;
}

// bbox: Vision normalized rect [x, y, w, h] → [x, y, w, h] (bottom-left origin)
static NSArray *bbox_array(CGRect r) {
    return @[@(r.origin.x), @(r.origin.y), @(r.size.width), @(r.size.height)];
}

// ── Perform Vision request synchronously ──

static NSArray *perform_request(VNImageRequestHandler *handler, VNRequest *request) {
    NSError *error = nil;
    [handler performRequests:@[request] error:&error];
    if (error) {
        NSLog(@"Vision request error: %@", error);
        return nil;
    }
    return request.results;
}

// ── OCR ──

static NSDictionary *do_ocr(CGImageRef image, int argc, char **argv) {
    VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] init];

    NSString *levelStr = noff_find_arg(argc, argv, "--level");
    if ([levelStr isEqualToString:@"fast"]) {
        request.recognitionLevel = VNRequestTextRecognitionLevelFast;
    } else {
        request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    }

    NSString *langStr = noff_find_arg(argc, argv, "--lang");
    if (langStr) {
        request.recognitionLanguages = [langStr componentsSeparatedByString:@","];
    } else {
        request.recognitionLanguages = @[@"en", @"zh-Hans", @"zh-Hant"];
    }
    request.usesLanguageCorrection = YES;

    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image
                                                                            options:@{}];
    NSArray *results = perform_request(handler, request);
    if (!results) return @{@"text": @"", @"blocks": @[]};

    NSMutableString *fullText = [NSMutableString string];
    NSMutableArray *blocks = [NSMutableArray array];

    for (VNRecognizedTextObservation *obs in results) {
        VNRecognizedText *top = [[obs topCandidates:1] firstObject];
        if (!top) continue;

        if (fullText.length > 0) [fullText appendString:@"\n"];
        [fullText appendString:top.string];

        [blocks addObject:@{
            @"text": top.string,
            @"confidence": @(top.confidence),
            @"bbox": bbox_array(obs.boundingBox),
        }];
    }

    NSMutableArray *detectedLangs = [NSMutableArray array];
    if (langStr) {
        [detectedLangs addObjectsFromArray:[langStr componentsSeparatedByString:@","]];
    }

    return @{
        @"text": fullText,
        @"blocks": blocks,
        @"languages": detectedLangs,
    };
}

// ── Barcode ──

static NSDictionary *do_barcode(CGImageRef image) {
    VNDetectBarcodesRequest *request = [[VNDetectBarcodesRequest alloc] init];

    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image
                                                                            options:@{}];
    NSArray *results = perform_request(handler, request);

    NSMutableArray *barcodes = [NSMutableArray array];
    for (VNBarcodeObservation *obs in results) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"payload"] = obs.payloadStringValue ?: @"";
        d[@"symbology"] = obs.symbology ?: @"";
        d[@"bbox"] = bbox_array(obs.boundingBox);
        [barcodes addObject:d];
    }

    return @{@"barcodes": barcodes, @"count": @(barcodes.count)};
}

// ── Classify ──

static NSDictionary *do_classify(CGImageRef image, NSInteger limit) {
    VNClassifyImageRequest *request = [[VNClassifyImageRequest alloc] init];

    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image
                                                                            options:@{}];
    NSArray *results = perform_request(handler, request);

    // Sort by confidence descending, filter high-confidence
    NSArray *sorted = [results sortedArrayUsingComparator:^NSComparisonResult(VNClassificationObservation *a, VNClassificationObservation *b) {
        return [@(b.confidence) compare:@(a.confidence)];
    }];

    NSMutableArray *classifications = [NSMutableArray array];
    for (VNClassificationObservation *obs in sorted) {
        if ((NSInteger)classifications.count >= limit) break;
        if (obs.confidence < 0.1) break; // skip very low confidence
        [classifications addObject:@{
            @"label": obs.identifier,
            @"confidence": @(obs.confidence),
        }];
    }

    return @{@"classifications": classifications, @"count": @(classifications.count)};
}

// ── Detect rectangles ──

static NSDictionary *do_detect(CGImageRef image, NSInteger limit) {
    VNDetectRectanglesRequest *request = [[VNDetectRectanglesRequest alloc] init];
    request.maximumObservations = limit;
    request.minimumConfidence = 0.3;

    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image
                                                                            options:@{}];
    NSArray *results = perform_request(handler, request);

    NSMutableArray *rects = [NSMutableArray array];
    for (VNRectangleObservation *obs in results) {
        [rects addObject:@{
            @"confidence": @(obs.confidence),
            @"bbox": bbox_array(obs.boundingBox),
            @"top_left": @[@(obs.topLeft.x), @(obs.topLeft.y)],
            @"top_right": @[@(obs.topRight.x), @(obs.topRight.y)],
            @"bottom_left": @[@(obs.bottomLeft.x), @(obs.bottomLeft.y)],
            @"bottom_right": @[@(obs.bottomRight.x), @(obs.bottomRight.y)],
        }];
    }

    return @{@"rectangles": rects, @"count": @(rects.count)};
}

// ── Faces ──

static NSDictionary *do_faces(CGImageRef image) {
    VNDetectFaceRectanglesRequest *request = [[VNDetectFaceRectanglesRequest alloc] init];

    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image
                                                                            options:@{}];
    NSArray *results = perform_request(handler, request);

    NSMutableArray *faces = [NSMutableArray array];
    for (VNFaceObservation *obs in results) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"confidence"] = @(obs.confidence);
        d[@"bbox"] = bbox_array(obs.boundingBox);
        if (obs.yaw) d[@"yaw"] = obs.yaw;
        if (obs.roll) d[@"roll"] = obs.roll;
        [faces addObject:d];
    }

    return @{@"faces": faces, @"count": @(faces.count)};
}

// ── Feature print (for similarity) ──

static VNFeaturePrintObservation *compute_feature_print(CGImageRef image) {
    VNGenerateImageFeaturePrintRequest *request = [[VNGenerateImageFeaturePrintRequest alloc] init];
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image
                                                                            options:@{}];
    NSArray *results = perform_request(handler, request);
    if (!results.count) return nil;
    return (VNFeaturePrintObservation *)results.firstObject;
}

// ── Similarity ──

static NSDictionary *do_similarity(NSArray<NSString *> *paths, float threshold) {
    NSMutableArray *featurePrints = [NSMutableArray array];
    NSMutableArray *imageInfos = [NSMutableArray array];

    for (NSString *path in paths) {
        NSInteger w = 0, h = 0;
        CGImageRef img = load_image(path, &w, &h);
        if (!img) {
            return @{@"error": [NSString stringWithFormat:@"Cannot load image: %@", path]};
        }
        VNFeaturePrintObservation *fp = compute_feature_print(img);
        if (!fp) {
            return @{@"error": [NSString stringWithFormat:@"Cannot compute feature print: %@", path]};
        }
        [featurePrints addObject:fp];
        [imageInfos addObject:@{@"path": path, @"width": @(w), @"height": @(h)}];
    }

    // Compute pairwise distances and convert to 0-1 similarity score
    NSMutableArray *pairs = [NSMutableArray array];
    NSMutableArray *duplicateGroups = [NSMutableArray array];
    // Track which images are duplicates (union-find via sets)
    NSMutableDictionary<NSNumber *, NSMutableSet<NSNumber *> *> *groups = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < featurePrints.count; i++) {
        groups[@(i)] = [NSMutableSet setWithObject:@(i)];
    }

    for (NSUInteger i = 0; i < featurePrints.count; i++) {
        for (NSUInteger j = i + 1; j < featurePrints.count; j++) {
            float distance = 0;
            NSError *error = nil;
            BOOL ok = [featurePrints[i] computeDistance:&distance toFeaturePrintObservation:featurePrints[j] error:&error];
            if (!ok) continue;

            // Convert distance to similarity score (empirical mapping)
            // Feature print distances are typically 0-70+, with <10 being very similar
            float similarity = fmaxf(0.0f, 1.0f - distance / 40.0f);

            BOOL isDuplicate = similarity >= threshold;
            [pairs addObject:@{
                @"image_a": @(i),
                @"image_b": @(j),
                @"path_a": paths[i],
                @"path_b": paths[j],
                @"distance": @(distance),
                @"similarity": @(similarity),
                @"is_duplicate": @(isDuplicate),
            }];

            // Merge groups if duplicate
            if (isDuplicate) {
                NSMutableSet *groupA = groups[@(i)];
                NSMutableSet *groupB = groups[@(j)];
                if (groupA != groupB) {
                    [groupA unionSet:groupB];
                    for (NSNumber *member in groupB) {
                        groups[member] = groupA;
                    }
                }
            }
        }
    }

    // Collect unique duplicate groups (only groups with >1 member)
    NSMutableSet *seen = [NSMutableSet set];
    for (NSUInteger i = 0; i < featurePrints.count; i++) {
        NSMutableSet *group = groups[@(i)];
        if (group.count > 1 && ![seen containsObject:group]) {
            [seen addObject:group];
            NSMutableArray *groupPaths = [NSMutableArray array];
            NSArray *sortedIndices = [group.allObjects sortedArrayUsingSelector:@selector(compare:)];
            for (NSNumber *idx in sortedIndices) {
                [groupPaths addObject:paths[idx.unsignedIntegerValue]];
            }
            [duplicateGroups addObject:groupPaths];
        }
    }

    return @{
        @"images": imageInfos,
        @"pairs": pairs,
        @"duplicate_groups": duplicateGroups,
        @"threshold": @(threshold),
        @"total_images": @(paths.count),
        @"duplicate_group_count": @(duplicateGroups.count),
    };
}

// ── Overlap (similar region detection between image pairs) ──

/// Check if a single row in pixelsA at rowOffsetA matches the row in pixelsB at rowOffsetB.
/// Uses per-channel tolerance (allows ±1 per R/G/B for anti-aliasing differences).
/// Returns the fraction of matching pixels (0.0 – 1.0).
static float row_match_score(const unsigned char *pixelsA, NSInteger rowOffsetA,
                              const unsigned char *pixelsB, NSInteger rowOffsetB,
                              NSInteger pixelCount, NSInteger tolerance) {
    NSInteger matched = 0;
    for (NSInteger x = 0; x < pixelCount * 4; x += 4) {
        int dr = abs((int)pixelsA[rowOffsetA + x]     - (int)pixelsB[rowOffsetB + x]);
        int dg = abs((int)pixelsA[rowOffsetA + x + 1] - (int)pixelsB[rowOffsetB + x + 1]);
        int db = abs((int)pixelsA[rowOffsetA + x + 2] - (int)pixelsB[rowOffsetB + x + 2]);
        if (dr <= tolerance && dg <= tolerance && db <= tolerance) {
            matched++;
        }
    }
    return pixelCount > 0 ? (float)matched / pixelCount : 0;
}

/// Find the vertical overlap between the bottom of imageA and the top of imageB.
///
/// Algorithm (two-phase anchor + verify):
///   Phase 1 – Anchor scan: pick an "anchor row" near the bottom of A (inside the
///             scrollable content area, skipping fixed UI).  Scan all rows in B's
///             scrollable area looking for a row that matches the anchor within
///             per-channel tolerance.
///   Phase 2 – Multi-row verify: for each anchor candidate, verify that N consecutive
///             rows around the anchor also match.  The candidate with the highest
///             verified match ratio wins.
///
/// skipTop / skipBottom let the caller exclude fixed UI (status bar, tab bar, etc.)
/// so those identical-but-non-scrolling rows don't create false matches.
static NSDictionary *find_overlap_info(CGImageRef imageA, CGImageRef imageB,
                                        NSInteger widthA, NSInteger heightA,
                                        NSInteger widthB, NSInteger heightB,
                                        float threshold,
                                        NSInteger skipTop, NSInteger skipBottom) {
    // Negative skips would push row offsets outside the pixel buffers below.
    skipTop = MAX(0, skipTop);
    skipBottom = MAX(0, skipBottom);

    // Step 1: Vision translational registration for coarse estimate
    VNTranslationalImageRegistrationRequest *regRequest =
        [[VNTranslationalImageRegistrationRequest alloc] initWithTargetedCGImage:imageB options:@{}];

    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:imageA options:@{}];
    NSError *error = nil;
    [handler performRequests:@[regRequest] error:&error];

    CGFloat visionTx = 0, visionTy = 0;
    CGFloat visionOverlapEstimate = 0;
    if (!error && regRequest.results.count > 0) {
        VNImageTranslationAlignmentObservation *obs = (VNImageTranslationAlignmentObservation *)regRequest.results.firstObject;
        CGAffineTransform t = obs.alignmentTransform;
        visionTx = t.tx;
        visionTy = t.ty;
        visionOverlapEstimate = fabs(t.ty) * heightA;
    }

    // Step 2: Rasterize both images into RGBA buffers for pixel comparison
    NSInteger sampleWidth = MIN(widthA, widthB);

    size_t bytesPerRowA = widthA * 4;
    size_t bytesPerRowB = widthB * 4;
    size_t bufSizeA = heightA * bytesPerRowA;
    size_t bufSizeB = heightB * bytesPerRowB;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();

    unsigned char *pixelsA = (unsigned char *)calloc(bufSizeA, 1);
    unsigned char *pixelsB = (unsigned char *)calloc(bufSizeB, 1);
    if (!pixelsA || !pixelsB) {
        free(pixelsA); free(pixelsB);
        CGColorSpaceRelease(colorSpace);
        return @{@"overlap_px": @((NSInteger)visionOverlapEstimate), @"confidence": @(0.3), @"method": @"vision_only"};
    }

    CGContextRef ctxA = CGBitmapContextCreate(pixelsA, widthA, heightA, 8, bytesPerRowA,
                                               colorSpace, kCGImageAlphaPremultipliedLast);
    CGContextRef ctxB = CGBitmapContextCreate(pixelsB, widthB, heightB, 8, bytesPerRowB,
                                               colorSpace, kCGImageAlphaPremultipliedLast);
    if (!ctxA || !ctxB) {
        if (ctxA) CGContextRelease(ctxA);
        if (ctxB) CGContextRelease(ctxB);
        free(pixelsA); free(pixelsB);
        CGColorSpaceRelease(colorSpace);
        return @{@"overlap_px": @((NSInteger)visionOverlapEstimate), @"confidence": @(0.3), @"method": @"vision_only"};
    }

    // Draw full images (CG coords: origin bottom-left, so y=0 is bottom row in memory)
    CGContextDrawImage(ctxA, CGRectMake(0, 0, widthA, heightA), imageA);
    CGContextDrawImage(ctxB, CGRectMake(0, 0, widthB, heightB), imageB);
    CGContextRelease(ctxA);
    CGContextRelease(ctxB);

    // Note: CGBitmapContext stores rows bottom-to-top in memory.
    // Row 0 in memory = bottom pixel row of the image.
    // Image row Y (from top, 0-based) = memory row (height - 1 - Y).

    // Scrollable content bounds (image coords, 0 = top)
    NSInteger contentTopA  = skipTop;
    NSInteger contentBotA  = heightA - skipBottom;  // exclusive
    NSInteger contentTopB  = skipTop;
    NSInteger contentBotB  = heightB - skipBottom;
    if (contentBotA <= contentTopA || contentBotB <= contentTopB) {
        free(pixelsA); free(pixelsB);
        CGColorSpaceRelease(colorSpace);
        return @{@"overlap_px": @(0), @"confidence": @(0), @"method": @"none",
                 @"error": @"skip-top + skip-bottom exceeds image height"};
    }
    NSInteger contentHeightA = contentBotA - contentTopA;

    // Per-channel tolerance: 1 per channel handles anti-aliasing differences.
    // With lower threshold the caller wants more leniency, so scale tolerance up.
    NSInteger pixelTolerance = threshold >= 0.98f ? 1 : (threshold >= 0.90f ? 3 : 8);

    // --- Phase 1: Anchor scan ---
    // Pick an anchor row from the bottom quarter of A's content area.
    // We try multiple anchor rows to handle cases where a single row might be
    // uniform (e.g. all white) and thus match everywhere.
    NSInteger anchorZoneStart = contentBotA - contentHeightA / 4;
    NSInteger anchorZoneEnd   = contentBotA - 1;
    NSInteger anchorStep      = MAX(1, (anchorZoneEnd - anchorZoneStart) / 5); // ~5 anchor candidates
    NSInteger verifyRows      = 30; // number of consecutive rows to verify

    // Best result across all anchors
    NSInteger bestOverlap = 0;
    float     bestVerifyScore = -1;

    for (NSInteger anchorImgY = anchorZoneStart; anchorImgY <= anchorZoneEnd; anchorImgY += anchorStep) {
        // Memory row for this image row
        NSInteger anchorMemRow = (heightA - 1 - anchorImgY);
        NSInteger anchorOffset = anchorMemRow * bytesPerRowA;

        // Scan B's content rows for a match to this anchor
        for (NSInteger bImgY = contentTopB; bImgY < contentBotB; bImgY++) {
            NSInteger bMemRow = (heightB - 1 - bImgY);
            NSInteger bOffset = bMemRow * bytesPerRowB;

            float score = row_match_score(pixelsA, anchorOffset, pixelsB, bOffset,
                                           sampleWidth, pixelTolerance);
            if (score < threshold) continue;

            // If A_row[anchorImgY] == B_row[bImgY], the overlap region is the
            // bottom N rows of A matching the top N rows of B, where:
            //   A_row[heightA - N + r] == B_row[r]  for r in [0, N)
            //   anchorImgY = heightA - N + bImgY  →  N = heightA - anchorImgY + bImgY
            NSInteger candidateOverlap = heightA - anchorImgY + bImgY;
            if (candidateOverlap < 10 || candidateOverlap > MIN(heightA, heightB)) continue;

            // --- Phase 2: Multi-row verification ---
            // Verify consecutive rows around the anchor point.
            NSInteger verified = 0;
            NSInteger checked  = 0;
            for (NSInteger k = -verifyRows/2; k <= verifyRows/2; k++) {
                NSInteger aY = anchorImgY + k;
                NSInteger bY = bImgY + k;
                if (aY < contentTopA || aY >= contentBotA) continue;
                if (bY < contentTopB || bY >= contentBotB) continue;

                NSInteger aOff = (heightA - 1 - aY) * bytesPerRowA;
                NSInteger bOff = (heightB - 1 - bY) * bytesPerRowB;
                float rs = row_match_score(pixelsA, aOff, pixelsB, bOff, sampleWidth, pixelTolerance);
                if (rs >= threshold) verified++;
                checked++;
            }

            float verifyScore = checked > 0 ? (float)verified / checked : 0;
            if (verifyScore > bestVerifyScore) {
                bestVerifyScore = verifyScore;
                bestOverlap = candidateOverlap;
            }

            // If we found a near-perfect match, skip further B rows for this anchor
            if (verifyScore > 0.95f) break;
        }
    }

    free(pixelsA);
    free(pixelsB);
    CGColorSpaceRelease(colorSpace);

    // Determine confidence level
    NSString *method;
    float confidence;
    if (bestVerifyScore >= threshold) {
        method = bestVerifyScore > 0.98f ? @"pixel_exact" : @"pixel_match";
        confidence = bestVerifyScore;
    } else if (visionOverlapEstimate > 0) {
        method = @"vision_estimate";
        bestOverlap = (NSInteger)visionOverlapEstimate;
        confidence = 0.5f;
    } else {
        method = @"none";
        bestOverlap = 0;
        confidence = 0;
    }

    return @{
        @"overlap_px": @(bestOverlap),
        @"confidence": @(confidence),
        @"threshold": @(threshold),
        @"method": method,
        @"skip_top": @(skipTop),
        @"skip_bottom": @(skipBottom),
        @"pixel_tolerance": @(pixelTolerance),
        @"vision_estimate": @{
            @"tx": @(visionTx),
            @"ty": @(visionTy),
            @"overlap_px": @((NSInteger)visionOverlapEstimate),
        },
        @"region_a": @{
            @"y": @(heightA - bestOverlap),
            @"height": @(bestOverlap),
            @"description": @"bottom of image A",
        },
        @"region_b": @{
            @"y": @(0),
            @"height": @(bestOverlap),
            @"description": @"top of image B",
        },
    };
}

static NSDictionary *do_overlap(NSArray<NSString *> *paths, float threshold,
                                 NSInteger skipTop, NSInteger skipBottom) {
    if (paths.count < 2) {
        return @{@"error": @"At least 2 images are required for overlap detection"};
    }

    NSMutableArray *imageInfos = [NSMutableArray array];
    NSMutableArray *cgImages = [NSMutableArray array]; // store as NSValue wrapping CGImageRef
    NSMutableArray *widths = [NSMutableArray array];
    NSMutableArray *heights = [NSMutableArray array];

    for (NSString *path in paths) {
        NSInteger w = 0, h = 0;
        CGImageRef img = load_image(path, &w, &h);
        if (!img) {
            return @{@"error": [NSString stringWithFormat:@"Cannot load image: %@", path]};
        }
        [cgImages addObject:[NSValue valueWithPointer:img]];
        [widths addObject:@(w)];
        [heights addObject:@(h)];
        [imageInfos addObject:@{
            @"index": @(imageInfos.count),
            @"path": path,
            @"width": @(w),
            @"height": @(h),
        }];
    }

    // Compute overlap for each consecutive pair
    NSMutableArray *pairResults = [NSMutableArray array];
    for (NSUInteger i = 0; i < paths.count - 1; i++) {
        CGImageRef imgA = (CGImageRef)[cgImages[i] pointerValue];
        CGImageRef imgB = (CGImageRef)[cgImages[i + 1] pointerValue];
        NSInteger wA = [widths[i] integerValue], hA = [heights[i] integerValue];
        NSInteger wB = [widths[i + 1] integerValue], hB = [heights[i + 1] integerValue];

        NSDictionary *overlapInfo = find_overlap_info(imgA, imgB, wA, hA, wB, hB,
                                                       threshold, skipTop, skipBottom);

        NSMutableDictionary *pair = [overlapInfo mutableCopy];
        pair[@"image_a"] = @{@"index": @(i), @"path": paths[i]};
        pair[@"image_b"] = @{@"index": @(i + 1), @"path": paths[i + 1]};
        [pairResults addObject:pair];
    }

    // Also compute whole-image feature print similarity for each pair
    NSMutableArray *featurePrints = [NSMutableArray array];
    for (NSUInteger i = 0; i < cgImages.count; i++) {
        CGImageRef img = (CGImageRef)[cgImages[i] pointerValue];
        VNFeaturePrintObservation *fp = compute_feature_print(img);
        [featurePrints addObject:fp ?: [NSNull null]];
    }

    for (NSUInteger i = 0; i < pairResults.count; i++) {
        NSMutableDictionary *pair = [pairResults[i] mutableCopy];
        if (featurePrints[i] != [NSNull null] && featurePrints[i + 1] != [NSNull null]) {
            float distance = 0;
            NSError *err = nil;
            BOOL ok = [(VNFeaturePrintObservation *)featurePrints[i]
                        computeDistance:&distance
                        toFeaturePrintObservation:(VNFeaturePrintObservation *)featurePrints[i + 1]
                        error:&err];
            if (ok) {
                float similarity = fmaxf(0.0f, 1.0f - distance / 40.0f);
                pair[@"feature_similarity"] = @{
                    @"distance": @(distance),
                    @"similarity": @(similarity),
                };
            }
        }
        [pairResults replaceObjectAtIndex:i withObject:pair];
    }

    return @{
        @"images": imageInfos,
        @"pairs": pairResults,
        @"pair_count": @(pairResults.count),
    };
}

// ── Analyze (combined) ──

static NSDictionary *do_analyze(CGImageRef image, int argc, char **argv) {
    NSDictionary *ocr = do_ocr(image, argc, argv);
    NSDictionary *barcode = do_barcode(image);
    NSDictionary *classify = do_classify(image, 5);
    NSDictionary *faces = do_faces(image);

    return @{
        @"ocr": @{
            @"text": ocr[@"text"] ?: @"",
            @"block_count": @([ocr[@"blocks"] count]),
        },
        @"classification": classify[@"classifications"] ?: @[],
        @"barcodes": barcode[@"barcodes"] ?: @[],
        @"faces": @{@"count": faces[@"count"] ?: @0},
    };
}

// ── Crop / Diff / Measure ──

// Rasterize a CGImage into a caller-owned RGBA buffer (top row first).
// Returns NULL on allocation failure.
static unsigned char *rasterize_rgba(CGImageRef image, NSInteger w, NSInteger h) {
    size_t rowBytes = (size_t)w * 4;
    unsigned char *px = (unsigned char *)calloc((size_t)h * rowBytes, 1);
    if (!px) return NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, w, h, 8, rowBytes, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(px); return NULL; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image);
    CGContextRelease(ctx);
    return px;
}

// Returns a +1 CGImageRef scaled to (w,h), or NULL on failure. Caller releases.
static CGImageRef scaled_cgimage(CGImageRef image, NSInteger w, NSInteger h) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, (size_t)w * 4, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image);
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return out;
}

static BOOL write_png_file(CGImageRef image, NSString *path) {
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)url, (__bridge CFStringRef)@"public.png", 1, NULL);
    if (!dest) return NO;
    CGImageDestinationAddImage(dest, image, NULL);
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    return ok;
}

// Parse "x,y,w,h" (integers). Returns NO on any format problem.
static BOOL parse_bbox_str(NSString *s, NSInteger *x, NSInteger *y, NSInteger *w, NSInteger *h) {
    if (!s) return NO;
    NSScanner *sc = [NSScanner scannerWithString:s];
    NSInteger vals[4];
    for (int i = 0; i < 4; i++) {
        if (![sc scanInteger:&vals[i]]) return NO;
        if (i < 3) {
            if (![sc scanString:@"," intoString:NULL]) return NO;
        }
    }
    if (!sc.isAtEnd) return NO;
    *x = vals[0]; *y = vals[1]; *w = vals[2]; *h = vals[3];
    return YES;
}

// Parse "x,y" (doubles). Returns NO on any format problem.
static BOOL parse_point_str(NSString *s, double *x, double *y) {
    if (!s) return NO;
    NSScanner *sc = [NSScanner scannerWithString:s];
    double vals[2];
    for (int i = 0; i < 2; i++) {
        if (![sc scanDouble:&vals[i]]) return NO;
        if (i == 0 && ![sc scanString:@"," intoString:NULL]) return NO;
    }
    if (!sc.isAtEnd) return NO;
    *x = vals[0]; *y = vals[1];
    return YES;
}

static NSDictionary *do_crop(NSString *path, NSString *bboxStr,
                              NSString *outputPath, double scale) {
    NSInteger imgW = 0, imgH = 0;
    CGImageRef img = load_image(path, &imgW, &imgH);
    if (!img) {
        return @{@"error": [NSString stringWithFormat:@"Cannot load image: %@", path]};
    }
    NSInteger bx, by, bw, bh;
    if (!parse_bbox_str(bboxStr, &bx, &by, &bw, &bh) || bw <= 0 || bh <= 0) {
        return @{@"error": @"Invalid --bbox. Use --bbox x,y,w,h in pixels (top-left origin), e.g. --bbox 0,0,100,200."};
    }
    // Clamp to image bounds (top-left origin space)
    NSInteger cx = MAX((NSInteger)0, bx);
    NSInteger cy = MAX((NSInteger)0, by);
    NSInteger cw = MIN(bw - (cx - bx), imgW - cx);
    NSInteger ch = MIN(bh - (cy - by), imgH - cy);
    if (cw <= 0 || ch <= 0) {
        return @{@"error": @"Crop region is outside the image bounds."};
    }
    // CoreGraphics rects use a bottom-left origin: flip y.
    CGRect cgRect = CGRectMake((CGFloat)cx, (CGFloat)(imgH - cy - ch),
                               (CGFloat)cw, (CGFloat)ch);
    CGImageRef cropped = CGImageCreateWithImageInRect(img, cgRect);
    if (!cropped) return @{@"error": @"Failed to crop image."};
    CGImageRef finalImg = cropped;
    BOOL didScale = NO;
    if (scale > 0 && fabs(scale - 1.0) > 1e-9) {
        double s = MIN(MAX(scale, 0.1), 8.0);
        NSInteger sw = MAX((NSInteger)1, (NSInteger)llround(cw * s));
        NSInteger sh = MAX((NSInteger)1, (NSInteger)llround(ch * s));
        if (sw > 4096 || sh > 4096) {
            double k = MIN(4096.0 / (double)sw, 4096.0 / (double)sh);
            sw = MAX((NSInteger)1, (NSInteger)llround(sw * k));
            sh = MAX((NSInteger)1, (NSInteger)llround(sh * k));
        }
        CGImageRef sc = scaled_cgimage(cropped, sw, sh);
        CGImageRelease(cropped);
        if (!sc) return @{@"error": @"Failed to scale cropped image."};
        finalImg = sc;
        didScale = YES;
    }
    NSInteger outW = (NSInteger)CGImageGetWidth(finalImg);
    NSInteger outH = (NSInteger)CGImageGetHeight(finalImg);
    NSString *out = outputPath;
    if (!out) {
        NSString *stem = [[path lastPathComponent] stringByDeletingPathExtension];
        NSString *dir = [path stringByDeletingLastPathComponent];
        out = [[dir stringByAppendingPathComponent:[stem stringByAppendingString:@".crop"]]
               stringByAppendingPathExtension:@"png"];
    }
    BOOL ok = write_png_file(finalImg, out);
    CGImageRelease(finalImg);
    if (!ok) {
        return @{@"error": [NSString stringWithFormat:@"Failed to write PNG: %@", out]};
    }
    NSMutableDictionary *d = [@{
        @"output": out,
        @"width": @(outW),
        @"height": @(outH),
        @"bbox_applied": @{@"x": @(cx), @"y": @(cy), @"width": @(cw), @"height": @(ch)},
        @"source": @{@"path": path, @"width": @(imgW), @"height": @(imgH)},
    } mutableCopy];
    if (didScale) d[@"scale"] = @(scale);
    return d;
}

#define DIFF_GRID 8
#define DIFF_MAX_PIXELS 16000000LL

static NSDictionary *do_diff(NSString *baselinePath, NSString *currentPath,
                              float threshold, NSString *outputPath) {
    NSInteger wA = 0, hA = 0, wB = 0, hB = 0;
    CGImageRef imgA = load_image(baselinePath, &wA, &hA);
    CGImageRef imgB = load_image(currentPath, &wB, &hB);
    if (!imgA) {
        return @{@"error": [NSString stringWithFormat:@"Cannot load baseline image: %@", baselinePath]};
    }
    if (!imgB) {
        return @{@"error": [NSString stringWithFormat:@"Cannot load current image: %@", currentPath]};
    }
    // Working size: baseline size, capped for speed/memory.
    NSInteger workW = wA, workH = hA;
    BOOL downscaled = NO;
    if ((long long)workW * workH > DIFF_MAX_PIXELS) {
        double k = sqrt((double)DIFF_MAX_PIXELS / ((double)workW * workH));
        workW = MAX((NSInteger)1, (NSInteger)llround(workW * k));
        workH = MAX((NSInteger)1, (NSInteger)llround(workH * k));
        downscaled = YES;
    }
    BOOL resized = (wB != wA || hB != hA);
    CGImageRef aWork = imgA, bWork = imgB;
    BOOL releaseA = NO, releaseB = NO;
    if (wA != workW || hA != workH) { aWork = scaled_cgimage(imgA, workW, workH); releaseA = YES; }
    if (wB != workW || hB != workH) { bWork = scaled_cgimage(imgB, workW, workH); releaseB = YES; }
    if (!aWork || !bWork) {
        if (releaseA) CGImageRelease(aWork);
        if (releaseB) CGImageRelease(bWork);
        return @{@"error": @"Failed to prepare images for comparison."};
    }
    unsigned char *pxA = rasterize_rgba(aWork, workW, workH);
    unsigned char *pxB = rasterize_rgba(bWork, workW, workH);
    if (releaseA) CGImageRelease(aWork);
    if (releaseB) CGImageRelease(bWork);
    if (!pxA || !pxB) {
        free(pxA); free(pxB);
        return @{@"error": @"Out of memory while comparing images."};
    }
    double thr = MAX(0.0, MIN(1.0, (double)threshold)) * 255.0;
    long long total = (long long)workW * workH;
    long long changed = 0;
    double sumDist = 0.0;
    BOOL cellHit[DIFF_GRID * DIFF_GRID] = { NO };
    for (NSInteger y = 0; y < workH; y++) {
        NSInteger cellY = (y * DIFF_GRID) / workH;
        for (NSInteger x = 0; x < workW; x++) {
            size_t i = ((size_t)y * (size_t)workW + (size_t)x) * 4;
            double dr = fabs((double)pxA[i] - (double)pxB[i]);
            double dg = fabs((double)pxA[i + 1] - (double)pxB[i + 1]);
            double db = fabs((double)pxA[i + 2] - (double)pxB[i + 2]);
            double d = (dr + dg + db) / 3.0;
            sumDist += d;
            if (d > thr) {
                changed++;
                NSInteger cellX = (x * DIFF_GRID) / workW;
                cellHit[cellY * DIFF_GRID + cellX] = YES;
            }
        }
    }
    // Union bbox of changed grid cells (pixels, top-left origin)
    id changedBbox = [NSNull null];
    NSInteger minCX = DIFF_GRID, minCY = DIFF_GRID, maxCX = -1, maxCY = -1;
    for (NSInteger cy = 0; cy < DIFF_GRID; cy++) {
        for (NSInteger cx = 0; cx < DIFF_GRID; cx++) {
            if (cellHit[cy * DIFF_GRID + cx]) {
                if (cx < minCX) minCX = cx;
                if (cy < minCY) minCY = cy;
                if (cx > maxCX) maxCX = cx;
                if (cy > maxCY) maxCY = cy;
            }
        }
    }
    if (maxCX >= 0) {
        NSInteger bx = (minCX * workW) / DIFF_GRID;
        NSInteger by = (minCY * workH) / DIFF_GRID;
        NSInteger bw = ((maxCX + 1) * workW) / DIFF_GRID - bx;
        NSInteger bh = ((maxCY + 1) * workH) / DIFF_GRID - by;
        changedBbox = @{@"x": @(bx), @"y": @(by), @"width": @(bw), @"height": @(bh)};
    }
    NSMutableDictionary *d = [@{
        @"mean_diff": @(sumDist / ((double)total * 255.0)),
        @"changed_fraction": @((double)changed / (double)total),
        @"changed_pixels": @(changed),
        @"changed_bbox": changedBbox,
        @"threshold": @(MAX(0.0, MIN(1.0, (double)threshold))),
        @"size": @{@"width": @(workW), @"height": @(workH)},
        @"resized": @(resized),
        @"downscaled": @(downscaled),
    } mutableCopy];
    // Optional heatmap: dimmed baseline, red overlay where changed
    if (outputPath) {
        unsigned char *heat = (unsigned char *)malloc((size_t)total * 4);
        if (heat) {
            for (long long p = 0; p < total; p++) {
                size_t i = (size_t)p * 4;
                double dr = fabs((double)pxA[i] - (double)pxB[i]);
                double dg = fabs((double)pxA[i + 1] - (double)pxB[i + 1]);
                double db = fabs((double)pxA[i + 2] - (double)pxB[i + 2]);
                double dd = (dr + dg + db) / 3.0;
                if (dd > thr) {
                    heat[i] = 255; heat[i + 1] = 0; heat[i + 2] = 0; heat[i + 3] = 255;
                } else {
                    heat[i] = pxA[i] / 2; heat[i + 1] = pxA[i + 1] / 2;
                    heat[i + 2] = pxA[i + 2] / 2; heat[i + 3] = 255;
                }
            }
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            CGContextRef hctx = CGBitmapContextCreate(heat, workW, workH, 8, (size_t)workW * 4,
                                                      cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
            CGColorSpaceRelease(cs);
            BOOL wrote = NO;
            if (hctx) {
                CGImageRef himg = CGBitmapContextCreateImage(hctx);
                CGContextRelease(hctx);
                if (himg) {
                    wrote = write_png_file(himg, outputPath);
                    CGImageRelease(himg);
                }
            }
            free(heat);
            d[@"output"] = outputPath;
            d[@"output_written"] = @(wrote);
        } else {
            d[@"output"] = outputPath;
            d[@"output_written"] = @(NO);
        }
    }
    free(pxA);
    free(pxB);
    return d;
}

static NSDictionary *do_measure(NSString *path, NSString *fromStr,
                                 NSString *toStr, double scale) {
    NSInteger imgW = 0, imgH = 0;
    CGImageRef img = load_image(path, &imgW, &imgH);
    if (!img) {
        return @{@"error": [NSString stringWithFormat:@"Cannot load image: %@", path]};
    }
    double x1, y1, x2, y2;
    if (!parse_point_str(fromStr, &x1, &y1)) {
        return @{@"error": @"Invalid --from. Use --from x,y in pixels (top-left origin)."};
    }
    if (!parse_point_str(toStr, &x2, &y2)) {
        return @{@"error": @"Invalid --to. Use --to x,y in pixels (top-left origin)."};
    }
    double dx = x2 - x1;
    double dy = y2 - y1;
    double dist = hypot(dx, dy);
    double s = scale > 0 ? scale : 1.0;
    double angle = atan2(dy, dx) * 180.0 / M_PI;
    return @{
        @"dx_px": @(dx),
        @"dy_px": @(dy),
        @"distance_px": @(dist),
        @"angle_deg": @(angle),
        @"scale": @(s),
        @"distance_css": @(dist / s),
        @"image": @{@"path": path, @"width": @(imgW), @"height": @(imgH)},
    };
}

static int vision_handler(int argc, char **argv,
                           int stdin_fd, int stdout_fd, int stderr_fd) {
    if (noff_has_flag(argc, argv, "--help") || noff_has_flag(argc, argv, "-h")) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        return NOFF_EXIT_SUCCESS;
    }

    BOOL compact = noff_has_flag(argc, argv, "--compact");
    BOOL quiet = noff_has_flag(argc, argv, "-q") || noff_has_flag(argc, argv, "--quiet");

    NSString *subcmd = noff_get_subcommand(argc, argv);
    if (!subcmd) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"unknown",
                                             NOFF_ERR_INVALID_ARGS,
                                             @"No command specified. Use --help for usage.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    // Get positional args (image paths)
    // NOTE: paths arrive already resolved to host filesystem by the iSH kernel,
    // so do NOT call noff_resolve_host_path() — that would double-resolve.
    NSArray *posArgs = noff_positional_args(argc, argv);

    // Multi-image commands: similarity, overlap
    if ([subcmd isEqualToString:@"similarity"]) {
        if (posArgs.count < 2) {
            NSDictionary *err = noff_json_error(TOOL_NAME, subcmd,
                                                 NOFF_ERR_INVALID_ARGS,
                                                 @"At least 2 image paths are required for similarity comparison.");
            noff_emit_json(stdout_fd, err, compact, quiet);
            return NOFF_EXIT_INVALID_ARGS;
        }
        NSString *threshStr = noff_find_arg(argc, argv, "--threshold");
        float threshold = threshStr ? [threshStr floatValue] : 0.9f;
        NSDictionary *data = do_similarity(posArgs, threshold);
        if (data[@"error"]) {
            NSDictionary *err = noff_json_error(TOOL_NAME, subcmd, NOFF_ERR_INTERNAL_ERROR, data[@"error"]);
            noff_emit_json(stdout_fd, err, compact, quiet);
            return NOFF_EXIT_ERROR;
        }
        noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, subcmd, data), compact, quiet);
        return NOFF_EXIT_SUCCESS;
    }

    if ([subcmd isEqualToString:@"overlap"]) {
        if (posArgs.count < 2) {
            NSDictionary *err = noff_json_error(TOOL_NAME, subcmd,
                                                 NOFF_ERR_INVALID_ARGS,
                                                 @"At least 2 image paths are required for overlap detection.");
            noff_emit_json(stdout_fd, err, compact, quiet);
            return NOFF_EXIT_INVALID_ARGS;
        }
        NSString *overlapThreshStr = noff_find_arg(argc, argv, "--threshold");
        float overlapThreshold = overlapThreshStr ? [overlapThreshStr floatValue] : 0.90f;
        NSString *skipTopStr = noff_find_arg(argc, argv, "--skip-top");
        NSString *skipBotStr = noff_find_arg(argc, argv, "--skip-bottom");
        NSInteger skipTop = skipTopStr ? [skipTopStr integerValue] : 0;
        NSInteger skipBot = skipBotStr ? [skipBotStr integerValue] : 0;
        NSDictionary *data = do_overlap(posArgs, overlapThreshold, skipTop, skipBot);
        if (data[@"error"]) {
            NSDictionary *err = noff_json_error(TOOL_NAME, subcmd, NOFF_ERR_INTERNAL_ERROR, data[@"error"]);
            noff_emit_json(stdout_fd, err, compact, quiet);
            return NOFF_EXIT_ERROR;
        }
        noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, subcmd, data), compact, quiet);
        return NOFF_EXIT_SUCCESS;
    }

    // crop: single image + --bbox (pixels, top-left origin)
    if ([subcmd isEqualToString:@"crop"]) {
        NSString *input = posArgs.firstObject;
        if (!input) input = noff_find_arg(argc, argv, "--input");
        NSString *bboxStr = noff_find_arg(argc, argv, "--bbox");
        if (!input || !bboxStr) {
            NSDictionary *err = noff_json_error(TOOL_NAME, subcmd,
                                                 NOFF_ERR_INVALID_ARGS,
                                                 @"crop needs an image path and --bbox x,y,w,h (pixels, top-left origin).");
            noff_emit_json(stdout_fd, err, compact, quiet);
            return NOFF_EXIT_INVALID_ARGS;
        }
        NSString *output = noff_find_arg(argc, argv, "--output");
        NSString *scaleStr = noff_find_arg(argc, argv, "--scale");
        double scale = scaleStr ? [scaleStr doubleValue] : 1.0;
        NSDictionary *data = do_crop(input, bboxStr, output, scale);
        if (data[@"error"]) {
            NSDictionary *err = noff_json_error(TOOL_NAME, subcmd, NOFF_ERR_INTERNAL_ERROR, data[@"error"]);
            noff_emit_json(stdout_fd, err, compact, quiet);
            return NOFF_EXIT_ERROR;
        }
        noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, subcmd, data), compact, quiet);
        return NOFF_EXIT_SUCCESS;
    }

    // diff: two images via --baseline/--current or positional args
    if ([subcmd isEqualToString:@"diff"]) {
        NSString *baseline = noff_find_arg(argc, argv, "--baseline");
        NSString *current = noff_find_arg(argc, argv, "--current");
        if (!baseline && posArgs.count > 0) baseline = posArgs[0];
        if (!current && posArgs.count > 1) current = posArgs[1];
        if (!baseline || !current) {
            NSDictionary *err = noff_json_error(TOOL_NAME, subcmd,
                                                 NOFF_ERR_INVALID_ARGS,
                                                 @"diff needs two images: --baseline a.png --current b.png (or two positional paths).");
            noff_emit_json(stdout_fd, err, compact, quiet);
            return NOFF_EXIT_INVALID_ARGS;
        }
        NSString *threshStr = noff_find_arg(argc, argv, "--threshold");
        float threshold = threshStr ? [threshStr floatValue] : 0.05f;
        NSString *output = noff_find_arg(argc, argv, "--output");
        NSDictionary *data = do_diff(baseline, current, threshold, output);
        if (data[@"error"]) {
            NSDictionary *err = noff_json_error(TOOL_NAME, subcmd, NOFF_ERR_INTERNAL_ERROR, data[@"error"]);
            noff_emit_json(stdout_fd, err, compact, quiet);
            return NOFF_EXIT_ERROR;
        }
        noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, subcmd, data), compact, quiet);
        return NOFF_EXIT_SUCCESS;
    }

    // measure: distance between two points
    if ([subcmd isEqualToString:@"measure"]) {
        NSString *input = posArgs.firstObject;
        if (!input) input = noff_find_arg(argc, argv, "--input");
        NSString *fromStr = noff_find_arg(argc, argv, "--from");
        NSString *toStr = noff_find_arg(argc, argv, "--to");
        if (!input || !fromStr || !toStr) {
            NSDictionary *err = noff_json_error(TOOL_NAME, subcmd,
                                                 NOFF_ERR_INVALID_ARGS,
                                                 @"measure needs an image path, --from x,y and --to x,y (pixels, top-left origin).");
            noff_emit_json(stdout_fd, err, compact, quiet);
            return NOFF_EXIT_INVALID_ARGS;
        }
        NSString *scaleStr = noff_find_arg(argc, argv, "--scale");
        double scale = scaleStr ? [scaleStr doubleValue] : 1.0;
        NSDictionary *data = do_measure(input, fromStr, toStr, scale);
        if (data[@"error"]) {
            NSDictionary *err = noff_json_error(TOOL_NAME, subcmd, NOFF_ERR_INTERNAL_ERROR, data[@"error"]);
            noff_emit_json(stdout_fd, err, compact, quiet);
            return NOFF_EXIT_ERROR;
        }
        noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, subcmd, data), compact, quiet);
        return NOFF_EXIT_SUCCESS;
    }

    // Single-image commands
    NSString *imagePath = posArgs.firstObject;

    if (!imagePath) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, subcmd,
                                             NOFF_ERR_INVALID_ARGS,
                                             @"No image path specified.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    // Load image
    NSInteger imgWidth = 0, imgHeight = 0;
    CGImageRef cgImage = load_image(imagePath, &imgWidth, &imgHeight);
    if (!cgImage) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, subcmd,
                                             NOFF_ERR_INVALID_ARGS,
                                             [NSString stringWithFormat:@"Cannot load image: %@", imagePath]);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }

    NSString *limitStr = noff_find_arg(argc, argv, "--limit");
    NSInteger limit = limitStr ? [limitStr integerValue] : 10;

    NSDictionary *data;

    if ([subcmd isEqualToString:@"ocr"]) {
        data = do_ocr(cgImage, argc, argv);
    } else if ([subcmd isEqualToString:@"barcode"]) {
        data = do_barcode(cgImage);
    } else if ([subcmd isEqualToString:@"classify"]) {
        data = do_classify(cgImage, limit);
    } else if ([subcmd isEqualToString:@"detect"]) {
        data = do_detect(cgImage, limit);
    } else if ([subcmd isEqualToString:@"faces"]) {
        data = do_faces(cgImage);
    } else if ([subcmd isEqualToString:@"analyze"]) {
        data = do_analyze(cgImage, argc, argv);
    } else {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, subcmd,
                                             NOFF_ERR_INVALID_ARGS,
                                             [NSString stringWithFormat:@"Unknown command '%@'. Valid commands: ocr, classify, detect, faces, barcode, analyze, similarity, overlap, crop, diff, measure. Use --help for details.", subcmd]);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }

    // Add image metadata
    NSMutableDictionary *enriched = [data mutableCopy];
    enriched[@"image"] = @{
        @"width": @(imgWidth),
        @"height": @(imgHeight),
        @"path": imagePath,
    };

    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, subcmd, enriched), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

void vision_offload_register(void) {
    int err = native_offload_add_handler("apple-vision", vision_handler);
    if (err == 0) {
        noff_ensure_guest_stub("/usr/local/bin/apple-vision");
        NSLog(@"NativeOffloads: apple-vision handler registered");
    } else {
        NSLog(@"NativeOffloads: failed to register apple-vision handler (err=%d)", err);
    }
}
