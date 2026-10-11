/*
 * Copyright (c) 2005-2018, BearWare.dk
 * 
 * Contact Information:
 *
 * Bjoern D. Rasmussen
 * Kirketoften 5
 * DK-8260 Viby J
 * Denmark
 * Email: contact@bearware.dk
 * Phone: +45 20 20 54 59
 * Web: http://www.bearware.dk
 *
 * This source code is part of the TeamTalk SDK owned by
 * BearWare.dk. Use of this file, or its compiled unit, requires a
 * TeamTalk SDK License Key issued by BearWare.dk.
 *
 * The TeamTalk SDK License Agreement along with its Terms and
 * Conditions are outlined in the file License.txt included with the
 * TeamTalk SDK distribution.
 *
 */

/*
 * The TeamTalk header and library files are located in 
 * the TeamTalk 5 SDK.
 *
 * To download the TeamTalk 5 SDK go to the GitHub website:
 *
 * https://github.com/BearWare/TeamTalk5
 *
 */

#import "../../../Library/TeamTalk_DLL/TeamTalk.h"
#import <zlib.h>

// Live sources of the media file stream (added to the TeamTalk library for
// TeamTalk NG): the "file" ttnglive:NAME streams the audio that read()
// returns, 20 msec of interleaved 16-bit samples at a time; 0 ends it.
typedef int (*TTNGLiveAudioRead)(void* context, short* buffer, int frames);
void TTNG_SetLiveAudioSource(const char* name, int samplerate, int channels,
                             TTNGLiveAudioRead read, void* context);
void TTNG_RemoveLiveAudioSource(const char* name);

// The client version sent at the next login, in place of the library
// version (added to the TeamTalk library for TeamTalk NG).
TTBOOL TTNG_SetClientVersion(TTInstance* lpTTInstance, const TTCHAR* szVersion);

Channel* getChannel(TTMessage* m);
User* getUser(TTMessage* m);
ServerProperties* getServerProperties(TTMessage* m);
UserAccount* getUserAccount(TTMessage* m);
BannedUser* getBannedUser(TTMessage* m);
TTBOOL getTTBOOL(TTMessage* m);
ClientErrorMsg* getClientErrorMsg(TTMessage* m);
TextMessage* getTextMessage(TTMessage* m);
SpeexCodec* getSpeexCodec(AudioCodec* a);
SpeexVBRCodec* getSpeexVBRCodec(AudioCodec* a);
OpusCodec* getOpusCodec(AudioCodec* a);
void setOpusCodec(AudioCodec* a, OpusCodec* o);
void setSpeexCodec(AudioCodec* a, SpeexCodec* s);
void setSpeexVBRCodec(AudioCodec* a, SpeexVBRCodec* s);

typedef struct StringWrap {
    TTCHAR buf[TT_STRLEN];
} StringWrap;

void convertTuple(const char* str, StringWrap* wrap);
TTCHAR* fromStringWrap(StringWrap* wrap);

typedef enum {
    NICKNAME,
    USERNAME,
    STATUSMSG,
    IPADDR,
    CLIENTNAME
} UExt;

typedef enum {
    NAME,
    PASSWORD,
    TOPIC,
    OPPASSWORD
} CExt;

typedef enum {
    MESSAGE
} MExt;

typedef enum {
    SERVERNAME,
    ACCESSTOKEN
} SExt;

typedef enum {
    ERRMESSAGE
} CEExt;

typedef enum {
    ACCOUNT_USERNAME,
    ACCOUNT_PASSWORD,
    ACCOUNT_NOTE,
    INITCHANNEL,
    ACCOUNT_LASTMODIFIED,
    ACCOUNT_LASTLOGIN
} UAExt;

typedef enum {
    BAN_IPADDRESS,
    BAN_CHANNELPATH,
    BAN_TIME,
    BAN_NICKNAME,
    BAN_USERNAME,
    BAN_OWNER
} BUExt;

const TTCHAR* getUserString(UExt e, const User* u);
const TTCHAR* getChannelString(CExt e, const Channel* c);
const TTCHAR* getTextMessageString(MExt e, const TextMessage* m);
const TTCHAR* getServerPropertiesString(SExt e, const ServerProperties* s);
const TTCHAR* getClientErrorMsgString(CEExt e, const ClientErrorMsg* m);
const TTCHAR* getUserAccountString(UAExt e, const UserAccount* u);
const TTCHAR* getBannedUserString(BUExt e, const BannedUser* u);

void setChannelString(CExt e, Channel* c, const TTCHAR* str);
void setUserAccountString(UAExt e, UserAccount* u, const TTCHAR* str);
