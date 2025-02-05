import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_boost/flutter_boost.dart';

class SimplePage extends StatefulWidget {
  final String data;

  const SimplePage({Key key, this.data}) : super(key: key);

  @override
  _SimplePageState createState() => _SimplePageState();
}

class _SimplePageState extends State<SimplePage> {
  TextEditingController _controller = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: CupertinoNavigationBar(
        leading: CupertinoNavigationBarBackButton(
          previousPageTitle: "MainPage",
          onPressed: () {
            BoostNavigator.instance.pop();
          },
        ),
      ),
      body: Center(
        child: Column(
          children: [
            const SizedBox(height: 100),
            const Text("Simple flutter page", style: TextStyle(fontSize: 26)),
            const SizedBox(height: 50),
            Text("data:${widget.data}", style: TextStyle(fontSize: 26)),
            const SizedBox(height: 50),
            Padding(
                padding: const EdgeInsets.all(8.0),
                child: CupertinoTextField(
                  controller: _controller,
                  padding: EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                  placeholder: 'data to return previous page',
                  decoration: BoxDecoration(color: Colors.amber),
                )),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: CupertinoButton.filled(
                padding: EdgeInsets.symmetric(vertical: 20, horizontal: 30),
                onPressed: () {
                  BoostNavigator.instance.pop(_controller.text);
                },
                child: Text('pop and return data',
                    style: TextStyle(
                        fontSize: 20,
                        color: Colors.white,
                        fontWeight: FontWeight.w500)),
              ),
            )
          ],
        ),
      ),
    );
  }
}
