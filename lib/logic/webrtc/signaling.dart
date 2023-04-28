/*
    Peer Chess : Play chess remotely with your friends.
    Copyright (C) 2023  Laurent Bernabe <laurent.bernabe@gmail.com>

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/
// Using code from https://github.com/flutter-webrtc/flutter-webrtc-demo/blob/master/lib/src/call_sample/random_string.dart

import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:firedart/firedart.dart';
import 'package:logger/logger.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

enum CreatingRoomState {
  success,
  alreadyCreatedARoom,
  miscError,
}

class Signaling {
  RTCDataChannel? _dataChannel;
  late RTCPeerConnection _myConnection;
  String? _selfId;
  String? _remoteId;
  String? _roomId;

  String? get selfId => _selfId;
  String? get remoteId => _remoteId;
  String? get roomId => _roomId;

  bool get remoteDescriptionNeeded =>
      _myConnection.connectionState !=
          RTCPeerConnectionState.RTCPeerConnectionStateConnected &&
      _myConnection.connectionState !=
          RTCPeerConnectionState.RTCPeerConnectionStateConnecting;

  late Map<String, dynamic> _iceServers;

  Signaling() {
    _initializeIceServers().then((value) => _createMyConnection());
  }

  Future<void> _initializeIceServers() async {
    final String credentialsText =
        await rootBundle.loadString('assets/secrets/turn_credentials.json');
    final credentials = await json.decode(credentialsText);

    final apiKey = credentials['apiKey'] as String;
    final response = await http.get(Uri.parse(
        "https://peer-chess.metered.live/api/v1/turn/credentials?apiKey=$apiKey"));

    // Saving the response in the iceServers array
    final serversText = response.body;
    final serversJson = await json.decode(serversText);
    _iceServers = {'iceServers': serversJson};
  }

  Future<void> _createMyConnection() async {
    Firestore.instance.collection('peers').stream.forEach((newElementsList) {
      if (_remoteId != null) {
        final remoteHasBeenDeleted =
            newElementsList.where((element) => element.id == _remoteId).isEmpty;
        if (remoteHasBeenDeleted) {
          Logger().i("Remote peer has been removed !");
        }
      }
    });
    final ourPeer = await Firestore.instance.collection('peers').add({});
    _selfId = ourPeer.id;
    final stream =
        await mediaDevices.getUserMedia({"audio": false, "video": false});
    _myConnection = await createPeerConnection(_iceServers);
    _myConnection.addStream(stream);
  }

  Future<CreatingRoomState> createRoom() async {
    // Checking that this peer is not already in a room
    final peerAlreadyInARoom = _roomId != null;
    if (peerAlreadyInARoom) return CreatingRoomState.alreadyCreatedARoom;

    // Save Room into DB and join this peer to it
    try {
      final room = await Firestore.instance.collection('rooms').add({
        "ownerId": _selfId,
      });
      // Marks this room as busy
      _roomId = room.id;

      // Sets ICE candidates handler
      _myConnection.onIceCandidate = (candidate) async {
        // Create OfferCandidate in DB
        await Firestore.instance
            .collection('offerCandidates')
            .add({'data': candidate.toMap(), 'ownerId': _selfId});
      };

      // Creates WebRTC offer
      final offer = await _myConnection.createOffer();
      await _myConnection.setLocalDescription(offer);

      // Save offer in db
      await Firestore.instance.collection('offers').add({
        'data': {
          "type": offer.type,
          "sdp": offer.sdp,
        },
        'ownerId': _selfId
      });

      return CreatingRoomState.success;
    } catch (ex) {
      Logger().e(ex);
      return CreatingRoomState.miscError;
    }
  }

  Future<void> deleteRoom() async {
    if (_roomId == null) return;
    var nextPageToken = '';

    // Deleting all related offer candidates
    var matchingOfferCandidates = <Document>[];
    while (true) {
      final offerCandidateInstancesPage =
          await Firestore.instance.collection('offerCandidates').get(
                nextPageToken: nextPageToken,
              );
      final goodOfferCandidates = offerCandidateInstancesPage
          .where((element) => element['ownerId'] == _selfId)
          .toList();
      matchingOfferCandidates.addAll(goodOfferCandidates);
      if (!offerCandidateInstancesPage.hasNextPage) break;
      nextPageToken = offerCandidateInstancesPage.nextPageToken;
    }
    for (var candidate in matchingOfferCandidates) {
      await candidate.reference.delete();
    }

    // Deleting all related offers
    nextPageToken = '';
    var matchingOffers = <Document>[];
    while (true) {
      final offerInstancesPage = await Firestore.instance
          .collection('offers')
          .get(nextPageToken: nextPageToken);
      final goodOffers = offerInstancesPage
          .where((element) => element['ownerId'] == _selfId)
          .toList();
      matchingOffers.addAll(goodOffers);
      if (!offerInstancesPage.hasNextPage) break;
      nextPageToken = offerInstancesPage.nextPageToken;
    }
    for (var offer in matchingOffers) {
      await offer.reference.delete();
    }

    // Deleting room
    nextPageToken = '';
    var matchingRooms = [];
    while (true) {
      final roomsInstancesPage = await Firestore.instance
          .collection('rooms')
          .get(nextPageToken: nextPageToken);
      final goodRooms = roomsInstancesPage
          .where((element) => element['ownerId'] == _selfId)
          .toList();
      matchingRooms.addAll(goodRooms);
      if (!roomsInstancesPage.hasNextPage) break;
      nextPageToken = roomsInstancesPage.nextPageToken;
    }
    for (var room in matchingRooms) {
      await room.reference.delete();
    }

    _roomId = null;
  }

  Future<void> removePeerFromDB() async {
    final peerInstance =
        Firestore.instance.collection('peers').document(_selfId!);
    await peerInstance.delete();
  }

  Future<void> setRemoteDescriptionFromAnswer(
      RTCSessionDescription description) async {
    await _myConnection.setRemoteDescription(description);
  }

  Future<void> addIceCandidate(RTCIceCandidate candidate) async {
    await _myConnection.addCandidate(candidate);
  }

  Future<void> removeSelfFromRoomJoiner() async {
    // todo removeSelfFromRoomJoiner
  }

  Function(RTCDataChannel dc, RTCDataChannelMessage data)? onDataChannelMessage;
  Function(RTCDataChannel dc)? onDataChannel;

  Future<void> _closeCall() async {
    await _myConnection.close();
    await _dataChannel?.close();
    _dataChannel = null;
  }

  void _addDataChannel(RTCDataChannel channel) {
    channel.onDataChannelState = (e) {};
    channel.onMessage = (RTCDataChannelMessage data) {
      onDataChannelMessage?.call(channel, data);
    };
    _dataChannel = channel;
    onDataChannel?.call(channel);
  }

  Future<void> _createDataChannel({label = 'dataTransfer'}) async {
    final dataChannelDict = RTCDataChannelInit()..maxRetransmits = 30;
    final channel =
        await _myConnection.createDataChannel(label, dataChannelDict);
    _addDataChannel(channel);
  }

  Future<void> hangUp() async {
    _closeCall();
  }
}
