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

import 'dart:async';
import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:firedart/firedart.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:peer_chess/logic/utils.dart';

enum CreatingRoomState {
  success,
  miscError,
}

enum JoiningRoomState {
  success,
  noRoomWithThisId,
  miscError,
}

class Signaling {
  RTCDataChannel? _dataChannel;
  RTCPeerConnection? _myConnection;
  String? _ourRoomId;
  String? _hostRoomId;
  final StreamController<bool> _readyToSendMessagesController =
      StreamController<bool>();
  final StreamController<Map<String, dynamic>> _remoteEventsController =
      StreamController<Map<String, dynamic>>();

  String? get ourRoomId => _ourRoomId;
  String? get hostRoomId => _hostRoomId;
  late Stream<bool> readyToSendMessagesStream;
  late Stream<Map<String, dynamic>> remoteEventsStream;
  late Map<String, dynamic> _iceServers;

  Signaling() {
    readyToSendMessagesStream = _readyToSendMessagesController.stream;
    remoteEventsStream = _remoteEventsController.stream;
    _initializeIceServers().then((value) => null);
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

  void addCandidate(RTCIceCandidate candidate) {
    if (_myConnection != null) _myConnection!.addCandidate(candidate);
  }

  Future<CreatingRoomState> createRoom() async {
    final newRoom = await Firestore.instance.collection('rooms').add({});
    _ourRoomId = newRoom.id;
    _myConnection = await createPeerConnection(_iceServers);
    await _setupDataChannel();

    // creating data channel
    final channelInit = RTCDataChannelInit();
    channelInit.ordered = true;
    _dataChannel =
        await _myConnection!.createDataChannel('mainChannel', channelInit);

    if (_myConnection != null) {
      // Collecting ice candidates
      _myConnection!.onIceCandidate = (candidate) async {
        // Add candidate to our peer document in DB
        await newRoom.reference
            .collection('callerCandidates')
            .add(candidate.toMap());
      };

      // Creates WebRTC offer
      final offer = await _myConnection!.createOffer();
      await _myConnection!.setLocalDescription(offer);

      // Add offer to our peer document in db
      final roomWithOffer = {
        'offer': {
          'type': offer.type,
          'sdp': offer.sdp,
        },
      };
      await newRoom.reference.set(roomWithOffer);

      return CreatingRoomState.success;
    } else {
      return CreatingRoomState.miscError;
    }
  }

  Future<JoiningRoomState> joinRoom({required String requestedRoomId}) async {
    // Checks that the host peer exists
    final allRooms = await getAllDocumentsFromCollection(
      collectionName: 'rooms',
    );
    final noMatchingRoom =
        allRooms.where((roomDoc) => roomDoc.id == requestedRoomId).isEmpty;
    if (noMatchingRoom) {
      return JoiningRoomState.noRoomWithThisId;
    }

    final hostRoom = await Firestore.instance
        .collection('rooms')
        .document(requestedRoomId)
        .get();

    _hostRoomId = hostRoom.id;

    _myConnection = await createPeerConnection(_iceServers);
    await _setupDataChannel();

    if (_myConnection != null) {
      _myConnection!.onIceCandidate = (candidate) async {
        // Add candidate to our peer document in DB
        await hostRoom.reference
            .collection('calleeCandidates')
            .add(candidate.toMap());
      };

      final offer = hostRoom['offer'];
      final offerDescription =
          RTCSessionDescription(offer['sdp'], offer['type']);
      await _myConnection?.setRemoteDescription(offerDescription);
      final answer = await _myConnection!.createAnswer();
      await _myConnection!.setLocalDescription(answer);
      await hostRoom.reference.set({
        'offer': hostRoom['offer'],
        'positiveAnswerFromHost': hostRoom['positiveAnswerFromHost'],
        'answer': {
          'sdp': answer.sdp,
          'type': answer.type,
        }
      });
      return JoiningRoomState.success;
    } else {
      return JoiningRoomState.miscError;
    }
  }

  Future<void> establishConnection() async {
    if (_myConnection != null && _ourRoomId != null) {
      final ourRoomDocument = await Firestore.instance
          .collection('rooms')
          .document(_ourRoomId!)
          .get();
      final answer = ourRoomDocument['answer'];
      final answerDescription =
          RTCSessionDescription(answer['sdp'], answer['type']);
      await _myConnection!.setRemoteDescription(answerDescription);
    }
  }

  Future<void> hangUp() async {
    await _closeCall();
  }

  Future<void> sendMessage(String message) async {
    await _dataChannel?.send(RTCDataChannelMessage(message));
  }

  Future<void> _setupDataChannel() async {
    final channelInit = RTCDataChannelInit();
    channelInit.ordered = true;
    _dataChannel =
        await _myConnection!.createDataChannel('mainChannel', channelInit);

    _myConnection?.onDataChannel = (channel) {
      channel.onMessage = (evt) {
        final data = evt.text;
        final dataAsJson = jsonDecode(data) as Map<String, dynamic>;
        _remoteEventsController.add(dataAsJson);
      };
    };

    _dataChannel!.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _readyToSendMessagesController.add(true);
      } else {
        _readyToSendMessagesController.add(false);
      }
    };
  }

  Future<void> _deleteRoomById(String id) async {
    final ourDocument =
        await Firestore.instance.collection('rooms').document(id).get();
    final callerCandidates = await getAllDocumentsFromSubCollection(
      parentDocument: ourDocument,
      collectionName: 'callerCandidates',
    );
    final calleeCandidates = await getAllDocumentsFromSubCollection(
      parentDocument: ourDocument,
      collectionName: 'calleeCandidates',
    );
    for (var candidate in callerCandidates) {
      await candidate.reference.delete();
    }
    for (var candidate in calleeCandidates) {
      await candidate.reference.delete();
    }
    await ourDocument.reference.delete();
  }

  Future<void> _deleteRoom() async {
    if (_ourRoomId != null) {
      await _deleteRoomById(_ourRoomId!);
      _dataChannel?.close();
      _myConnection?.close();
      _dataChannel = null;
      _myConnection = null;
      _ourRoomId = null;
    }
  }

  Future<void> _closeCall() async {
    await _deleteRoom();
    await _myConnection?.close();
    await _dataChannel?.close();
    _dataChannel = null;
    _myConnection = null;
    _ourRoomId = null;
    _hostRoomId = null;
  }

  Future<void> dispose() async {
    await _readyToSendMessagesController.close();
    await _remoteEventsController.close();
  }
}
