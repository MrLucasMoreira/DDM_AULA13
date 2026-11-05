
import 'dotenv/config';

import express from 'express';
import cors from 'cors';
import multer from 'multer';

import { randomUUID } from 'node:crypto';
import { fileTypeFromBuffer } from 'file-type';

import { createClient } from '@supabase/supabase-js';

import { initializeApp } from 'firebase/app';
import {
  getDatabase,
  ref,
  get,
  set,
  runTransaction
} from 'firebase/database';

const app = express();
const port = 3000;

// =======================================
// FIREBASE
// =======================================

const firebaseConfig = {
  apiKey: process.env.FIREBASE_API_KEY,
  authDomain: 'ddmapi.firebaseapp.com',
  databaseURL: 'https://ddmapi-default-rtdb.firebaseio.com',
  projectId: 'ddmapi',
  storageBucket: 'ddmapi.firebasestorage.app',
  messagingSenderId: '724860875864',
  appId: '1:724860875864:web:9dae57c24ef0b3606f462d'
};

const firebaseApp = initializeApp(firebaseConfig);
const db = getDatabase(firebaseApp);

// =======================================
// SUPABASE
// =======================================

if (
  !process.env.SUPABASE_URL ||
  !process.env.SUPABASE_SECRET_KEY
) {
  throw new Error('Configure as variáveis do Supabase.');
}

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SECRET_KEY,
  {
    auth: {
      persistSession: false,
      autoRefreshToken: false
    }
  }
);

const bucket = 'publicacoes';

// =======================================
// MIDDLEWARES
// =======================================

app.use(cors());
app.use(express.json());

// =======================================
// MULTER
// =======================================

const upload = multer({
  storage: multer.memoryStorage(),
  limits: {
    fileSize: 5 * 1024 * 1024
  }
});

const extensoes = {
  'image/jpeg': '.jpg',
  'image/png': '.png',
  'image/webp': '.webp'
};

// =======================================
// VERIFICAR BUCKET
// =======================================

async function verificarBucket() {
  try {
    const { data, error } =
      await supabase.storage.listBuckets();

    if (error) {
      console.error(
        'Erro ao listar buckets:',
        error.message
      );
      return;
    }

    console.log(
      'Buckets encontrados:',
      data.map(b => b.name)
    );

    const existe = data.some(b => b.id === bucket);

    console.log(
      existe
        ? `Bucket "${bucket}" encontrado!`
        : `Bucket "${bucket}" NÃO encontrado!`
    );
  } catch (erro) {
    console.error(
      'Erro na verificação:',
      erro.message
    );
  }
}

verificarBucket();

app.use(express.static('public'));

// =======================================
// ROTA INICIAL
// =======================================

app.get('/', (req, res) => {
  res.json({
    mensagem: 'API Mini X funcionando!'
  });
});

// =======================================
// SALVAR PUBLICAÇÃO
// =======================================

app.post(
  '/salvar',
  upload.single('imagem'),
  async (req, res) => {

    let caminhoImagem = null;
    let uploadConcluido = false;

    try {
      const texto = String(
        req.body.texto || ''
      ).trim();

      if (!texto && !req.file) {
        return res.status(400).json({
          erro: 'Informe texto ou imagem.'
        });
      }

      if (texto.length > 280) {
        return res.status(400).json({
          erro: 'Máximo de 280 caracteres.'
        });
      }

      let imagemUrl = null;

      // =================================
      // UPLOAD DA IMAGEM
      // =================================

      if (req.file) {
        console.log(
          'Imagem recebida:',
          req.file.originalname
        );

        console.log(
          'Tamanho:',
          req.file.size
        );

        const tipo = await fileTypeFromBuffer(
          req.file.buffer
        );

        console.log(
          'Tipo identificado:',
          tipo?.mime
        );

        if (!tipo || !extensoes[tipo.mime]) {
          return res.status(400).json({
            erro: 'Formato inválido. Use JPG, PNG ou WebP.'
          });
        }

        const nomeArquivo =
          `${randomUUID()}${extensoes[tipo.mime]}`;

        caminhoImagem = `posts/${nomeArquivo}`;

        console.log(
          'Enviando para Supabase:',
          caminhoImagem
        );

        const { data, error } =
          await supabase.storage
            .from(bucket)
            .upload(
              caminhoImagem,
              req.file.buffer,
              {
                contentType: tipo.mime,
                upsert: false
              }
            );

        if (error) {
          console.error(
            'ERRO SUPABASE:',
            JSON.stringify({
              message: error.message,
              statusCode: error.statusCode,
              error: error.error
            }, null, 2)
          );

          return res.status(
            Number(error.statusCode) || 500
          ).json({
            erro: `Erro no Supabase: ${error.message}`,
            codigo: error.statusCode
          });
        }

        uploadConcluido = true;

        console.log(
          'Upload realizado:',
          data
        );

        const { data: urlData } =
          supabase.storage
            .from(bucket)
            .getPublicUrl(caminhoImagem);

        imagemUrl = urlData.publicUrl;
      }

      // =================================
      // GERAR ID NO FIREBASE
      // =================================

      const contadorRef = ref(db, 'contador');

      const resultado = await runTransaction(
        contadorRef,
        atual => (atual || 0) + 1
      );

      if (!resultado.committed) {
        throw new Error('Falha ao gerar ID.');
      }

      const id = resultado.snapshot.val();

      // =================================
      // MONTAR PUBLICAÇÃO
      // =================================

      const publicacao = {
        id,
        texto,
        imagemUrl,
        criadoEm: new Date().toISOString()
      };

      // =================================
      // SALVAR NO FIREBASE
      // =================================

      await set(
        ref(db, `dados/${id}`),
        publicacao
      );

      console.log(
        'Publicação salva:',
        id
      );

      return res.status(201).json({
        mensagem: 'Publicado com sucesso!',
        ...publicacao
      });

    } catch (erro) {
      console.error(
        'ERRO AO PUBLICAR:',
        erro
      );

      // Remover imagem somente se
      // o upload tiver sido concluído
      if (uploadConcluido && caminhoImagem) {
        try {
          const { error } =
            await supabase.storage
              .from(bucket)
              .remove([caminhoImagem]);

          if (error) {
            console.error(
              'Erro ao remover imagem:',
              error.message
            );
          }
        } catch (erroLimpeza) {
          console.error(
            'Erro na limpeza:',
            erroLimpeza.message
          );
        }
      }

      return res.status(500).json({
        erro: erro.message
      });
    }
  }
);

// =======================================
// BUSCAR PRÓXIMA PUBLICAÇÃO
// =======================================

app.get('/buscar', async (req, res) => {
  try {
    if (req.query.id === undefined) {
      return res.status(400).json({
        erro: 'Informe um ID.'
      });
    }

    const id = Number(req.query.id);

    if (!Number.isSafeInteger(id) || id < 0) {
      return res.status(400).json({
        erro: 'ID inválido.'
      });
    }

    const snapshot = await get(
      ref(db, 'dados')
    );

    if (!snapshot.exists()) {
      return res.status(404).json({
        mensagem: 'Nenhum registro encontrado.'
      });
    }

    const proximo = Object.values(
      snapshot.val()
    )
      .filter(dado => dado.id > id)
      .sort((a, b) => a.id - b.id)[0];

    if (!proximo) {
      return res.status(404).json({
        mensagem: 'Não existem publicações posteriores.'
      });
    }

    return res.status(200).json(proximo);

  } catch (erro) {
    console.error(
      'Erro na busca:',
      erro
    );

    return res.status(500).json({
      erro: erro.message
    });
  }
});

// =======================================
// VERIFICAR STORAGE (DIAGNÓSTICO)
// =======================================

app.get('/debug/storage', async (req, res) => {
  try {
    const { data, error } =
      await supabase.storage.listBuckets();

    if (error) {
      return res.status(500).json({
        erro: error.message,
        codigo: error.statusCode
      });
    }

    return res.json({
      bucketConfigurado: bucket,
      bucketsEncontrados: data.map(b => ({
        id: b.id,
        nome: b.name,
        publico: b.public
      })),
      existe: data.some(b => b.id === bucket)
    });

  } catch (erro) {
    return res.status(500).json({
      erro: erro.message
    });
  }
});

// =======================================
// HEALTH CHECK
// =======================================

app.get('/health', (req, res) => {
  return res.status(200).json({
    status: 'UP',
    timestamp: new Date().toISOString()
  });
});

// =======================================
// TRATAMENTO DE ERROS
// =======================================

app.use((erro, req, res, next) => {
  if (erro instanceof multer.MulterError) {
    return res.status(400).json({
      erro: erro.code === 'LIMIT_FILE_SIZE'
        ? 'Imagem maior que 5 MB.'
        : erro.message
    });
  }

  console.error('Erro interno:', erro);

  return res.status(500).json({
    erro: 'Erro interno do servidor.'
  });
});


// =======================================
// FEED DE PUBLICAÇÕES
// =======================================

app.get('/feed', async (req, res) => {
  try {
    const snapshot = await get(ref(db, 'dados'));

    if (!snapshot.exists()) {
      return res.status(200).json([]);
    }

    const publicacoes = Object.values(snapshot.val())
      .filter(post => post && typeof post === 'object')
      .sort((a, b) => Number(b.id) - Number(a.id));

    return res.status(200).json(publicacoes);

  } catch (erro) {
    console.error('Erro ao carregar feed:', erro);

    return res.status(500).json({
      erro: 'Erro ao carregar publicações.'
    });
  }
});


// =======================================
// INICIAR SERVIDOR
// =======================================

app.listen(port, () => {
  console.log(
    `Servidor rodando em http://localhost:${port}`
  );
});
