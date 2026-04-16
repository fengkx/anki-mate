#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <Foundation/Foundation.h>

/* Opaque type for a dictionary reference — same layout as the private DCSDictionaryRef. */
typedef const void* DCSDictRef;

/* Returns a collection (NSArray or NSSet) of DCSDictRef opaque elements representing
   every dictionary installed on this system.  Caller owns the result. */
extern id DCSCopyAvailableDictionaries(void) NS_RETURNS_RETAINED;

/* Returns the display name of the given dictionary (e.g. "New Oxford American Dictionary").
   This is a "Get" (borrowed reference) — caller does NOT own the result. */
extern NSString* _Nullable DCSDictionaryGetName(DCSDictRef dict);

/* Returns a collection (NSArray or NSSet) of opaque record objects matching the search string.
   The last two parameters are undocumented; pass NULL for both.  Caller owns the result. */
extern id DCSCopyRecordsForSearchString(DCSDictRef dict, NSString* string, void* reserved1, void* reserved2) NS_RETURNS_RETAINED;

/* Copies the full HTML content for a record returned by DCSCopyRecordsForSearchString.
   Caller must release. */
extern NSString* DCSRecordCopyData(id record) NS_RETURNS_RETAINED;

/* Returns (without copy) the headword string for a record.
   Borrowed reference — caller does NOT own the result. */
extern NSString* _Nullable DCSRecordGetString(id record);
