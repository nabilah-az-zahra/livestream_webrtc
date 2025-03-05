// import 'package:flutter/material.dart';
// import 'package:google_fonts/google_fonts.dart';
// import 'package:livestream_webrtc/screens/livestream.dart';

// class ProfilePage extends StatefulWidget {
//   const ProfilePage({super.key});

//   @override
//   State<ProfilePage> createState() => _ProfilePageState();
// }

// class _ProfilePageState extends State<ProfilePage>
//     with SingleTickerProviderStateMixin {
//   final String streamerName = "Streamer Name";
//   final String profilePictureUrl = "https://via.placeholder.com/150";

//   late TabController _tabController;

//   @override
//   void initState() {
//     super.initState();
//     _tabController =
//         TabController(length: 1, vsync: this); // Single tab "Video"
//   }

//   void _navigateToLiveStream(BuildContext context, String streamId,
//       String streamTitle, String streamerName) {
//     Navigator.push(
//       context,
//       MaterialPageRoute(
//         builder: (context) => LiveStreamPage(
//           streamTitle: streamTitle,
//           streamerName: streamerName,
//           streamId: streamId,
//         ),
//       ),
//     );
//   }

//   @override
//   Widget build(BuildContext context) {
//     return Scaffold(
//       body: SafeArea(
//         child: Column(
//           children: [
//             // Back Button
//             Padding(
//               padding: const EdgeInsets.all(8.0),
//               child: Row(
//                 children: [
//                   IconButton(
//                     icon: const Icon(Icons.arrow_back, color: Colors.black),
//                     onPressed: () {
//                       Navigator.pop(context);
//                     },
//                   ),
//                 ],
//               ),
//             ),

//             // Profile Section
//             Padding(
//               padding: const EdgeInsets.symmetric(vertical: 16.0),
//               child: Column(
//                 children: [
//                   CircleAvatar(
//                     radius: 60,
//                     backgroundImage: NetworkImage(profilePictureUrl),
//                     backgroundColor: Colors.grey.shade200,
//                   ),
//                   const SizedBox(height: 12),
//                   Text(
//                     streamerName,
//                     style: GoogleFonts.kanit(
//                       fontSize: 24,
//                       fontWeight: FontWeight.bold,
//                       color: const Color(0xFF1E1E1E),
//                     ),
//                   ),
//                 ],
//               ),
//             ),

//             // Tab Bar
//             TabBar(
//               controller: _tabController,
//               labelColor: const Color(0xFF1E1E1E),
//               labelStyle: GoogleFonts.kanit(
//                 fontSize: 16,
//                 fontWeight: FontWeight.bold,
//               ),
//               unselectedLabelColor: Colors.grey,
//               indicatorColor: const Color(0xFF1E1E1E),
//               tabs: const [
//                 Tab(text: "Video"),
//               ],
//             ),

//             // Tab Bar View
//             Expanded(
//               child: TabBarView(
//                 controller: _tabController,
//                 children: [
//                   ListView.builder(
//                     itemCount: 5, // Replace with actual number of videos
//                     itemBuilder: (context, index) {
//                       String streamTitle = "Stream Title ${index + 1}";
//                       String streamerName = "Streamer ${index + 1}";
//                       String streamId = "Stream ID ${index + 1}";

//                       return GestureDetector(
//                         onTap: () => _navigateToLiveStream(
//                           context,
//                           streamTitle,
//                           streamerName,
//                           streamId,
//                         ),
//                         child: Column(
//                           children: <Widget>[
//                             Stack(
//                               children: <Widget>[
//                                 Container(
//                                   color: const Color(0xFFD9D9D9),
//                                   height: 176.0,
//                                   alignment: Alignment.center,
//                                   child: Text("Content ${index + 1}"),
//                                 ),
//                                 Positioned(
//                                   top: 10.0,
//                                   left: 10.0,
//                                   child: Container(
//                                     color: const Color(0xFFAA4A4D),
//                                     height: 20.0,
//                                     width: 38.0,
//                                     child: const Text(
//                                       "LIVE",
//                                       textAlign: TextAlign.center,
//                                       style: TextStyle(
//                                         color: Color(0xFFFFFFFF),
//                                       ),
//                                     ),
//                                   ),
//                                 ),
//                               ],
//                             ),
//                             Padding(
//                               padding: const EdgeInsets.symmetric(
//                                   horizontal: 20.0, vertical: 12.0),
//                               child: Row(
//                                 children: <Widget>[
//                                   Column(
//                                     crossAxisAlignment:
//                                         CrossAxisAlignment.start,
//                                     children: <Widget>[
//                                       Text(
//                                         streamTitle,
//                                         style: GoogleFonts.kanit(
//                                           fontSize: 16,
//                                           fontWeight: FontWeight.w500,
//                                           color: const Color(0xFF000000),
//                                         ),
//                                       ),
//                                     ],
//                                   ),
//                                 ],
//                               ),
//                             ),
//                           ],
//                         ),
//                       );
//                     },
//                   ),
//                 ],
//               ),
//             ),
//           ],
//         ),
//       ),
//     );
//   }
// }
