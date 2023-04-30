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

enum JoiningRoomState {
  success,
  noRoomWithThisId,
  alreadySomeonePairingWithHost,
  miscError,
}

class Signaling {
  RTCDataChannel? _dataChannel;
  late RTCPeerConnection _myConnection;
  String? _selfId;
  Document? _ourPeerDocumentInDb;

  String? get selfId => _selfId;

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
      if (_ourPeerDocumentInDb?['remoteId'] != null) {
        final remoteHasBeenDeleted = newElementsList
            .where((element) => element.id == _ourPeerDocumentInDb?['remoteId'])
            .isEmpty;
        if (remoteHasBeenDeleted) {
          Logger().i("Remote peer has been removed !");
        }
      }
    });
    _ourPeerDocumentInDb = await Firestore.instance.collection('peers').add({});
    _selfId = _ourPeerDocumentInDb?.reference.id;
    final stream =
        await mediaDevices.getUserMedia({"audio": false, "video": false});
    _myConnection = await createPeerConnection(_iceServers);
    _myConnection.addStream(stream);
  }

  Future<CreatingRoomState> createRoom() async {
    // Checking that this peer is not already in a room
    final peerAlreadyInARoom = _ourPeerDocumentInDb?['roomOpened'] == true;
    if (peerAlreadyInARoom) return CreatingRoomState.alreadyCreatedARoom;

    // Marks room as opened in db.
    try {
      await _ourPeerDocumentInDb?.reference.set({'roomOpened': true});

      // Sets ICE candidates handler
      _myConnection.onIceCandidate = (candidate) async {
        // Add candidate to our peer document in DB
        await _ourPeerDocumentInDb?.reference
            .collection('candidates')
            .add(candidate.toMap());
      };

      // Creates WebRTC offer
      final offer = await _myConnection.createOffer();
      await _myConnection.setLocalDescription(offer);

      // Add offer to our peer document in db
      await _ourPeerDocumentInDb?.reference
          .collection('offers')
          .add(offer.toMap());

      return CreatingRoomState.success;
    } catch (ex) {
      Logger().e(ex);
      await _ourPeerDocumentInDb?.reference.set({'roomOpened': false});
      return CreatingRoomState.miscError;
    }
  }

  Future<void> removeOurselfFromRoom() async {
    final remotePeer = await Firestore.instance
        .collection('peers')
        .document(_ourPeerDocumentInDb?['remoteId'])
        .get();
    if (await remotePeer.reference.exists) {
      final ourAnswers = await _getAllDocumentsFromSubCollection(
          parentDocument: _ourPeerDocumentInDb!, collectionName: 'answers');
      for (var answer in ourAnswers) {
        await answer.reference.delete();
      }
      await remotePeer.reference.set({'remoteId': null});
    }
    await _ourPeerDocumentInDb?.reference.set({'remoteId': null});
  }

  Future<List<Document>> _getAllDocumentsFromSubCollection({
    required Document parentDocument,
    required String collectionName,
  }) async {
    var nextPageToken = '';
    var results = <Document>[];
    while (true) {
      final instances =
          await parentDocument.reference.collection(collectionName).get(
                nextPageToken: nextPageToken,
              );
      results.addAll(instances);
      if (!instances.hasNextPage) break;
      nextPageToken = instances.nextPageToken;
    }

    return results;
  }

  Future<JoiningRoomState> joinRoom(
      {required String requestedPeerId, required String requestMessage}) async {
    // Checks that the host peer exists
    final hostPeerInstance = await Firestore.instance
        .collection('peers')
        .document(requestedPeerId)
        .get();
    final peerExists = await hostPeerInstance.reference.exists;
    if (!peerExists) {
      return JoiningRoomState.noRoomWithThisId;
    }

    // Checks that the host peer has opened a room
    if (!hostPeerInstance['roomOpened']) {
      return JoiningRoomState.noRoomWithThisId;
    }

    // Checks that nobody is connecting with the room's host
    if (hostPeerInstance['remoteId'] != null) {
      return JoiningRoomState.alreadySomeonePairingWithHost;
    }

    // Search the offer from the host
    final hostOffers = await _getAllDocumentsFromSubCollection(
        collectionName: 'offers', parentDocument: hostPeerInstance);

    if (hostOffers.isEmpty) {
      Logger().e('No offer register for the host !');
    }
    final offerFromHost = hostOffers.first;

    // Set remote description with offer from host
    final sdp = offerFromHost['sdp'];
    final type = offerFromHost['type'];
    final remoteSessionDescription = RTCSessionDescription(sdp, type);
    _myConnection.setRemoteDescription(remoteSessionDescription);

    // Registers the joiner of the room in the DB
    await hostPeerInstance.reference.set({'remoteId': _selfId!});
    await _ourPeerDocumentInDb!.reference.set({'remoteId': requestedPeerId});

    // Sets the ICE candidates from the offer
    final matchingCandidates =
        await hostPeerInstance.reference.collection('candidates').get();
    if (matchingCandidates.isEmpty) {
      Logger().e('No related ICE candidates !');
      return JoiningRoomState.miscError;
    }

    for (var candidate in matchingCandidates) {
      final candidateData = candidate;
      _myConnection.addCandidate(
        RTCIceCandidate(
          candidateData['candidate'],
          candidateData['sdpMid'],
          candidateData['sdpMLineIndex'],
        ),
      );
    }

    // Sets ICE candidates handler
    _myConnection.onIceCandidate = (candidate) async {
      // Create OfferCandidate instance
      await _ourPeerDocumentInDb?.reference
          .collection('candidates')
          .add(candidate.toMap());
    };

    // Creates WebRTC offer
    final answer = await _myConnection.createAnswer();

    // Save answer in db
    await _ourPeerDocumentInDb?.reference
        .collection('answers')
        .add(answer.toMap());

    return JoiningRoomState.success;
  }

  Future<void> establishConnection() async {
    // Set the remote description in the local WebRTC connection.
    final remoteDocument = await Firestore.instance
        .collection('peer')
        .document(_ourPeerDocumentInDb?['remoteId'])
        .get();
    final allRemoteAnswers = await _getAllDocumentsFromSubCollection(
        parentDocument: remoteDocument, collectionName: 'answers');
    final remoteAnswer = allRemoteAnswers.first;
    final answer = RTCSessionDescription(
      remoteAnswer['sdp'],
      remoteAnswer['type'],
    );
    await _myConnection.setRemoteDescription(answer);

    // Set the local description in the local WebRTC connection.
    // Important :
    /// Must be done after the remote description has been set in the
    /// local WebRTC connection !
    final allLocalOffers = await _getAllDocumentsFromSubCollection(
        parentDocument: _ourPeerDocumentInDb!, collectionName: 'offers');
    final localOffer = allLocalOffers.first;
    final offer = RTCSessionDescription(
      localOffer['sdp'],
      localOffer['type'],
    );
    await _myConnection.setLocalDescription(offer);

    // Delete answers from remote peer
    for (var answer in allRemoteAnswers) {
      await answer.reference.delete();
    }

    // Delete offers from local peer
    for (var offer in allLocalOffers) {
      await offer.reference.delete();
    }

    // Create data channel
    final channelInit = RTCDataChannelInit();
    channelInit.binaryType = "blob";
    channelInit.protocol = "json";
    channelInit.ordered = true;
    _dataChannel =
        await _myConnection.createDataChannel('myChannel', channelInit);

    _dataChannel?.onMessage = (RTCDataChannelMessage data) {
      Logger().d("Got channel data : $data");
    };
  }

  Future<void> deleteRoom() async {
    // Deleting all related offers
    final relatedOffers = await _getAllDocumentsFromSubCollection(
        parentDocument: _ourPeerDocumentInDb!, collectionName: 'offers');
    for (var offer in relatedOffers) {
      await offer.reference.delete();
    }

    // Mark room as closed
    await _ourPeerDocumentInDb?.reference.set({'roomOpened': false});
  }

  Future<void> removePeerFromDB() async {
    final allLocalOffers = await _getAllDocumentsFromSubCollection(
      parentDocument: _ourPeerDocumentInDb!,
      collectionName: 'offers',
    );
    final allLocalAnswers = await _getAllDocumentsFromSubCollection(
      parentDocument: _ourPeerDocumentInDb!,
      collectionName: 'answers',
    );
    final allLocalCandidates = await _getAllDocumentsFromSubCollection(
      parentDocument: _ourPeerDocumentInDb!,
      collectionName: 'candidates',
    );

    for (var offer in allLocalOffers) {
      await offer.reference.delete();
    }
    for (var answer in allLocalAnswers) {
      await answer.reference.delete();
    }
    for (var candidate in allLocalCandidates) {
      await candidate.reference.delete();
    }
    await _ourPeerDocumentInDb?.reference.delete();
  }

  Future<void> setRemoteDescriptionFromAnswer(
      RTCSessionDescription description) async {
    await _myConnection.setRemoteDescription(description);
  }

  Future<void> addIceCandidate(RTCIceCandidate candidate) async {
    await _myConnection.addCandidate(candidate);
  }

  Future<void> _closeCall() async {
    await _myConnection.close();
    await _dataChannel?.close();
    _dataChannel = null;
  }

  Future<void> hangUp() async {
    await _closeCall();
  }
}
