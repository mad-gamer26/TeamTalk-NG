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

#import <Foundation/Foundation.h>

#include "iTeamTalk-Bridging-Header.h"

Channel* getChannel(TTMessage* m) {
    return &m->channel;
}

User* getUser(TTMessage* m) {
    return &m->user;
}

ServerProperties* getServerProperties(TTMessage* m) {
    return &m->serverproperties;
}

UserAccount* getUserAccount(TTMessage* m) {
    return &m->useraccount;
}

BannedUser* getBannedUser(TTMessage* m) {
    return &m->banneduser;
}

TTBOOL getTTBOOL(TTMessage* m) {
    return m->bActive;
}

ClientErrorMsg* getClientErrorMsg(TTMessage* m){
    return &m->clienterrormsg;
}

TextMessage* getTextMessage(TTMessage* m) {
    return &m->textmessage;
}

SpeexCodec* getSpeexCodec(AudioCodec* a) {
    return &a->speex;
}

SpeexVBRCodec* getSpeexVBRCodec(AudioCodec* a) {
    return &a->speex_vbr;
}

OpusCodec* getOpusCodec(AudioCodec* a) {
    return &a->opus;
}

void setOpusCodec(AudioCodec* a, OpusCodec* o) {
    a->nCodec = OPUS_CODEC;
    a->opus = *o;
}

void setSpeexCodec(AudioCodec* a, SpeexCodec* s) {
    a->nCodec = SPEEX_CODEC;
    a->speex = *s;
}

void setSpeexVBRCodec(AudioCodec* a, SpeexVBRCodec* s) {
    a->nCodec = SPEEX_VBR_CODEC;
    a->speex_vbr = *s;
}

void convertTuple(const char* str, StringWrap* wrap) {
    strncpy(wrap->buf, str, TT_STRLEN);
}

TTCHAR* fromStringWrap(StringWrap* wrap) {
    return &wrap->buf[0];
}

const TTCHAR* getUserString(UExt e, const User* u) {
    switch (e) {
        case NICKNAME :
            return u->szNickname;
        case USERNAME :
            return u->szUsername;
        case STATUSMSG :
            return u->szStatusMsg;
        case IPADDR :
            return u->szIPAddress;
        case CLIENTNAME :
            return u->szClientName;
    }
    return "";
}

const TTCHAR* getChannelString(CExt e, const Channel* c) {
    switch (e) {
        case NAME :
            return c->szName;
        case PASSWORD :
            return c->szPassword;
        case OPPASSWORD :
            return c->szOpPassword;
        case TOPIC :
            return c->szTopic;
    }
    return "";
}

const TTCHAR* getTextMessageString(MExt e, const TextMessage* m) {
    switch (e) {
        case MESSAGE :
            return m->szMessage;
    }
    return "";
}

const TTCHAR* getServerPropertiesString(SExt e, const ServerProperties* s) {
    switch (e) {
        case SERVERNAME :
            return s->szServerName;
        case ACCESSTOKEN :
            return s->szAccessToken;
    }
    return "";
}

const TTCHAR* getClientErrorMsgString(CEExt e, const ClientErrorMsg* m) {
    switch (e) {
        case ERRMESSAGE :
            return m->szErrorMsg;
    }
    return "";
}

const TTCHAR* getUserAccountString(UAExt e, const UserAccount* u) {
    switch (e) {
        case ACCOUNT_USERNAME : return u->szUsername;
        case ACCOUNT_PASSWORD : return u->szPassword;
        case ACCOUNT_NOTE : return u->szNote;
        case INITCHANNEL : return u->szInitChannel;
        case ACCOUNT_LASTMODIFIED : return u->szLastModified;
        case ACCOUNT_LASTLOGIN : return u->szLastLoginTime;
    }
    return "";
}

const TTCHAR* getBannedUserString(BUExt e, const BannedUser* u) {
    switch (e) {
        case BAN_IPADDRESS : return u->szIPAddress;
        case BAN_CHANNELPATH : return u->szChannelPath;
        case BAN_TIME : return u->szBanTime;
        case BAN_NICKNAME : return u->szNickname;
        case BAN_USERNAME : return u->szUsername;
        case BAN_OWNER : return u->szOwner;
    }
    return "";
}

void setChannelString(CExt e, Channel* c, const TTCHAR* str) {
    switch (e) {
        case NAME :
            strncpy(c->szName, str, TT_STRLEN);
            break;
        case PASSWORD :
            strncpy(c->szPassword, str, TT_STRLEN);
            break;
        case OPPASSWORD :
            strncpy(c->szOpPassword, str, TT_STRLEN);
            break;
        case TOPIC :
            strncpy(c->szTopic, str, TT_STRLEN);
            break;
    }
}
void setUserAccountString(UAExt e, UserAccount* u, const TTCHAR* str) {
    switch (e) {
        case ACCOUNT_USERNAME :
            strncpy(u->szUsername, str, TT_STRLEN);
            break;
        case ACCOUNT_PASSWORD :
            strncpy(u->szPassword, str, TT_STRLEN);
            break;
        case ACCOUNT_NOTE :
            strncpy(u->szNote, str, TT_STRLEN);
            break;
        case INITCHANNEL :
            strncpy(u->szInitChannel, str, TT_STRLEN);
            break;
        case ACCOUNT_LASTMODIFIED :
        case ACCOUNT_LASTLOGIN :
            break;
    }
}

