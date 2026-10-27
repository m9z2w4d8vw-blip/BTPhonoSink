/* Long-lived SDP objects. No pointers into a temporary stack array.
 * Attribute stride 24, element stride 16, descriptor two (pointer,count) pairs.
 * Derived from the binary Source arrays at +0x91ABD0, +0x91AC30,
 * +0x91AC50, primitive values at +0x773678..6D8, record add +0x1E8E78.
 * SDP publication is NOT proven until externally discovered over Bluetooth. */
#include "BTPSV82SDP.h"
#include <stddef.h>
#include <string.h>
typedef struct { uint8_t type, reserved; uint16_t length; uint32_t padding; uint64_t value; } Element;
typedef struct { uint16_t id; uint8_t padding[6]; Element element; } Attr;
typedef struct { const Attr *a; uint16_t count_a; uint8_t reserved_a[6];
                 const Attr *b; uint16_t count_b; uint8_t reserved_b[6]; } Descriptor;
#if defined(__cplusplus)
static_assert(sizeof(Element)==16 && sizeof(Attr)==24 && sizeof(Descriptor)==32, "private SDP layout changed");
#else
_Static_assert(sizeof(Element)==16 && sizeof(Attr)==24 && sizeof(Descriptor)==32, "private SDP layout changed");
#endif
#define U16(v) {3,0,4,0,(v)}
#define UINT16(v) {1,0,2,0,(v)}
#define SEQ(n,p) {6,0,(n),0,(uint64_t)(uintptr_t)(p)}
#define TXT(n,p) {4,0,(n),0,(uint64_t)(uintptr_t)(p)}
static const Element serviceClass[] = {U16(0x110Bu)};
static const Element l2capFields[] = {U16(0x0100u), UINT16(0x0019u)};
static const Element avdtpFields[] = {U16(0x0019u), UINT16(0x0103u)};
static const Element profileFields[] = {U16(0x110Du), UINT16(0x0103u)};
static const Element protocolList[] = {SEQ(2,l2capFields), SEQ(2,avdtpFields)};
static const Element profileList[] = {SEQ(2,profileFields)};
static const char sinkName[] = "Audio Sink";
static const Attr attributes[] = {
    {0x0001, {0}, SEQ(1,serviceClass)},
    {0x0004, {0}, SEQ(2,protocolList)},
    {0x0009, {0}, SEQ(1,profileList)},
    {0x0311, {0}, UINT16(0x0001u)}, /* A2DP Headphone supported feature */
};
static const Attr strings[] = {
    {0x0100, {0}, TXT(10,sinkName)},
};
static const Descriptor description = {attributes, 4, {0}, strings, 1, {0}};
const void *BTPSV82SinkSDPDescriptor(void) { return &description; }
