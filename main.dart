
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'X Bolsonaro | Publicações',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color.fromARGB(255, 7, 190, 38),
        ),
        useMaterial3: true,
      ),
      home: const TelaPublicacao(),
    );
  }
}

class TelaPublicacao extends StatefulWidget {
  const TelaPublicacao({super.key});

  @override
  State<TelaPublicacao> createState() => _TelaPublicacaoState();
}

class _TelaPublicacaoState extends State<TelaPublicacao> {
  static String get apiUrl {
    if (kIsWeb) {
      return 'http://localhost:3000';
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      return 'http://10.0.2.2:3000';
    }

    return 'http://localhost:3000';
  }

  final textoController = TextEditingController();
  final idController = TextEditingController();
  final ImagePicker picker = ImagePicker();

  XFile? imagemSelecionada;
  Uint8List? imagemBytes;
  MediaType? imagemTipo;

  List<Map<String, dynamic>> publicacoes = [];
  Map<String, dynamic>? publicacaoBuscada;

  bool carregando = false;
  bool carregandoFeed = false;
  String? erroFeed;

  @override
  void initState() {
    super.initState();
    carregarFeed();
  }

  void mostrarMensagem(String mensagem) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(mensagem),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ==================================
  // IMAGENS
  // ==================================

  MediaType? identificarMime(String nome) {
    final extensao = nome.split('.').last.toLowerCase();

    switch (extensao) {
      case 'jpg':
      case 'jpeg':
        return MediaType('image', 'jpeg');

      case 'png':
        return MediaType('image', 'png');

      case 'webp':
        return MediaType('image', 'webp');

      default:
        return null;
    }
  }

  Future<void> selecionarImagem(ImageSource origem) async {
    try {
      final imagem = await picker.pickImage(
        source: origem,
        imageQuality: 75,
        maxWidth: 1600,
      );

      if (imagem == null) return;

      final tipo = identificarMime(imagem.name);

      if (tipo == null) {
        mostrarMensagem('Use imagens JPG, PNG ou WebP.');
        return;
      }

      final bytes = await imagem.readAsBytes();

      if (bytes.length > 5 * 1024 * 1024) {
        mostrarMensagem('Imagem maior que 5 MB.');
        return;
      }

      if (!mounted) return;

      setState(() {
        imagemSelecionada = imagem;
        imagemBytes = bytes;
        imagemTipo = tipo;
      });

    } catch (e) {
      mostrarMensagem('Erro ao selecionar imagem: $e');
    }
  }

  void removerImagem() {
    setState(() {
      imagemSelecionada = null;
      imagemBytes = null;
      imagemTipo = null;
    });
  }

  // ==================================
  // PUBLICAR
  // ==================================

  Future<void> publicar() async {
    final texto = textoController.text.trim();

    if (texto.isEmpty && imagemBytes == null) {
      mostrarMensagem('Digite um texto ou escolha uma foto.');
      return;
    }

    setState(() {
      carregando = true;
    });

    try {
      final requisicao = http.MultipartRequest(
        'POST',
        Uri.parse('$apiUrl/salvar'),
      );

      requisicao.fields['texto'] = texto;

      if (imagemSelecionada != null &&
          imagemBytes != null &&
          imagemTipo != null) {
        requisicao.files.add(
          http.MultipartFile.fromBytes(
            'imagem',
            imagemBytes!,
            filename: imagemSelecionada!.name,
            contentType: imagemTipo,
          ),
        );
      }

      final stream = await requisicao
          .send()
          .timeout(const Duration(seconds: 30));

      final resposta = await http.Response.fromStream(stream);
      final dados = jsonDecode(resposta.body);

      if (!mounted) return;

      if (resposta.statusCode == 200 ||
          resposta.statusCode == 201) {
        textoController.clear();
        removerImagem();

        FocusScope.of(context).unfocus();

        mostrarMensagem('Publicado com sucesso!');

        // Atualizar automaticamente o feed
        await carregarFeed();
      } else {
        mostrarMensagem(
          'Erro: ${dados['erro'] ?? 'Falha na publicação'}',
        );
      }
    } catch (e) {
      mostrarMensagem('Erro ao publicar: $e');
    } finally {
      if (mounted) {
        setState(() {
          carregando = false;
        });
      }
    }
  }

  // ==================================
  // CARREGAR FEED
  // ==================================

  Future<void> carregarFeed() async {
    if (!mounted) return;

    setState(() {
      carregandoFeed = true;
      erroFeed = null;
    });

    try {
      final resposta = await http
          .get(Uri.parse('$apiUrl/feed'))
          .timeout(const Duration(seconds: 15));

      if (resposta.statusCode != 200) {
        throw Exception(
          'Servidor retornou ${resposta.statusCode}'
        );
      }

      final dados = jsonDecode(resposta.body);

      if (dados is! List) {
        throw Exception('Formato de feed inválido.');
      }

      final lista = dados
          .whereType<Map<String, dynamic>>()
          .toList();

      lista.sort((a, b) {
        final idA = int.tryParse('${a['id']}') ?? 0;
        final idB = int.tryParse('${b['id']}') ?? 0;
        return idB.compareTo(idA);
      });

      if (!mounted) return;

      setState(() {
        publicacoes = lista;
      });

    } catch (e) {
      if (!mounted) return;

      setState(() {
        erroFeed = 'Não foi possível carregar o feed.';
      });

      debugPrint('Erro no feed: $e');
    } finally {
      if (mounted) {
        setState(() {
          carregandoFeed = false;
        });
      }
    }
  }

  // ==================================
  // BUSCAR PELO ID
  // ==================================

  Future<void> buscar() async {
    final id = int.tryParse(idController.text.trim());

    if (id == null || id < 0) {
      mostrarMensagem('Informe um ID válido.');
      return;
    }

    setState(() {
      carregando = true;
      publicacaoBuscada = null;
    });

    try {
      final resposta = await http
          .get(Uri.parse('$apiUrl/buscar?id=$id'))
          .timeout(const Duration(seconds: 15));

      final dados = jsonDecode(resposta.body);

      if (!mounted) return;

      if (resposta.statusCode == 200 && dados is Map) {
        setState(() {
          publicacaoBuscada = Map<String, dynamic>.from(dados);
        });

        mostrarMensagem('Publicação encontrada!');
      } else {
        mostrarMensagem(
          dados is Map
              ? '${dados['mensagem'] ?? dados['erro'] ?? 'Não encontrada'}'
              : 'Publicação não encontrada.',
        );
      }

    } catch (e) {
      mostrarMensagem('Erro ao buscar: $e');
    } finally {
      if (mounted) {
        setState(() {
          carregando = false;
        });
      }
    }
  }

  // ==================================
  // UTILITÁRIOS
  // ==================================

  String formatarData(dynamic valor) {
    if (valor == null) return '';

    final data = DateTime.tryParse('$valor');

    if (data == null) return '';

    final local = data.toLocal();

    String dois(int n) => n.toString().padLeft(2, '0');

    return '${dois(local.day)}/${dois(local.month)}/${local.year}'
        ' às ${dois(local.hour)}:${dois(local.minute)}';
  }

  String resolverImagem(dynamic url) {
    if (url == null || '$url'.isEmpty) return '';

    return Uri.parse(apiUrl).resolve('$url').toString();
  }

  // ==================================
  // CARD DE PUBLICAÇÃO
  // ==================================

  Widget cardPublicacao(Map<String, dynamic> post) {
    final texto = '${post['texto'] ?? ''}';
    final imagemUrl = resolverImagem(post['imagemUrl']);
    final id = '${post['id'] ?? '-'}';

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Colors.grey.shade200,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Autor
            Row(
              children: [
                const CircleAvatar(
                  radius: 21,
                  backgroundColor: Colors.blue,
                  child: Icon(
                    Icons.person,
                    color: Colors.white,
                  ),
                ),

                const SizedBox(width: 10),

                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Usuário',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      Text(
                        '@usuario · Post #$id',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),

                const Icon(
                  Icons.more_horiz,
                  color: Colors.grey,
                ),
              ],
            ),

            const SizedBox(height: 14),

            // Texto
            if (texto.isNotEmpty)
              Text(
                texto,
                style: const TextStyle(
                  fontSize: 15,
                  height: 1.45,
                ),
              ),

            // Foto
            if (imagemUrl.isNotEmpty) ...[
              const SizedBox(height: 12),

              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(
                  imagemUrl,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  loadingBuilder: (
                    context,
                    child,
                    progress,
                  ) {
                    if (progress == null) return child;

                    return const SizedBox(
                      height: 180,
                      child: Center(
                        child: CircularProgressIndicator(),
                      ),
                    );
                  },
                  errorBuilder: (
                    context,
                    error,
                    stackTrace,
                  ) {
                    return const SizedBox(
                      height: 100,
                      child: Center(
                        child: Text(
                          'Não foi possível carregar a foto.',
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],

            const SizedBox(height: 12),

            Text(
              formatarData(post['criadoEm']),
              style: const TextStyle(
                fontSize: 12,
                color: Colors.grey,
              ),
            ),

            const Divider(height: 25),

            // Ações visuais do post
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                Icon(
                  Icons.chat_bubble_outline,
                  size: 21,
                  color: Colors.grey,
                ),
                Icon(
                  Icons.favorite_border,
                  size: 21,
                  color: Colors.grey,
                ),
                Icon(
                  Icons.repeat,
                  size: 21,
                  color: Colors.grey,
                ),
                Icon(
                  Icons.share_outlined,
                  size: 21,
                  color: Colors.grey,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ==================================
  // INTERFACE
  // ==================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FA),

      appBar: AppBar(
        title: const Text('X Bolsonaro | Publicações'),
        backgroundColor: Colors.blue.shade900,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Atualizar feed',
            onPressed: carregandoFeed ? null : carregarFeed,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),

      body: RefreshIndicator(
        onRefresh: carregarFeed,

        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            // ==========================
            // NOVA PUBLICAÇÃO
            // ==========================

            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: Colors.blue,
                        child: Icon(
                          Icons.person,
                          color: Colors.white,
                        ),
                      ),
                      SizedBox(width: 12),
                      Text(
                        'Nova publicação',
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 18),

                  TextField(
                    controller: textoController,
                    maxLines: 3,
                    maxLength: 280,
                    decoration: const InputDecoration(
                      hintText: 'O que está acontecendo?',
                      border: InputBorder.none,
                    ),
                  ),

                  if (imagemBytes != null) ...[
                    Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.memory(
                            imagemBytes!,
                            width: double.infinity,
                            height: 220,
                            fit: BoxFit.cover,
                          ),
                        ),
                        Positioned(
                          top: 8,
                          right: 8,
                          child: IconButton.filled(
                            onPressed: carregando
                                ? null
                                : removerImagem,
                            icon: const Icon(Icons.close),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],

                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Galeria',
                        onPressed: carregando
                            ? null
                            : () => selecionarImagem(
                                  ImageSource.gallery,
                                ),
                        icon: const Icon(Icons.image),
                        color: Colors.blue.shade900,
                      ),

                      IconButton(
                        tooltip: 'Câmera',
                        onPressed: carregando
                            ? null
                            : () => selecionarImagem(
                                  ImageSource.camera,
                                ),
                        icon: const Icon(Icons.camera_alt),
                        color: Colors.blue.shade900,
                      ),

                      const Spacer(),

                      FilledButton.icon(
                        onPressed: carregando ? null : publicar,
                        icon: const Icon(Icons.send, size: 18),
                        label: Text(
                          carregando ? 'Enviando...' : 'Publicar',
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.blue.shade900,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 25),

            // ==========================
            // BUSCAR PUBLICAÇÃO
            // ==========================

            const Text(
              'Buscar Publicação',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 12),

            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: idController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'ID inicial',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),

                const SizedBox(width: 10),

                IconButton.filled(
                  onPressed: carregando ? null : buscar,
                  icon: const Icon(Icons.search),
                ),
              ],
            ),

            if (publicacaoBuscada != null) ...[
              const SizedBox(height: 15),
              cardPublicacao(publicacaoBuscada!),
            ],

            const SizedBox(height: 30),

            // ==========================
            // FEED
            // ==========================

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Feed de Publicações',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),

                IconButton(
                  onPressed:
                      carregandoFeed ? null : carregarFeed,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),

            const SizedBox(height: 14),

            if (carregandoFeed &&
                publicacoes.isEmpty)
              const Padding(
                padding: EdgeInsets.all(30),
                child: Center(
                  child: CircularProgressIndicator(),
                ),
              ),

            if (erroFeed != null) ...[
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Text(
                      erroFeed!,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton(
                      onPressed: carregarFeed,
                      child: const Text('Tentar novamente'),
                    ),
                  ],
                ),
              ),
            ],

            if (!carregandoFeed &&
                erroFeed == null &&
                publicacoes.isEmpty)
              const Padding(
                padding: EdgeInsets.all(30),
                child: Center(
                  child: Text(
                    'Nenhuma publicação ainda.\n'
                    'Seja o primeiro a publicar!',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),

            // LISTAGEM DE PUBLICAÇÕES
            ...publicacoes.map(cardPublicacao),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    textoController.dispose();
    idController.dispose();
    super.dispose();
  }
}
